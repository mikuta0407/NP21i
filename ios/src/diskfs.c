/**
 * @file	diskfs.c
 * @brief	Reading and writing files in PC-98 disk images (FAT12/16/32)
 *
 * The image is seen as a disk: a byte array without the image's header
 * (D88 images are mapped sector by sector). On it, partitions are found
 * from the PC-98 partition table in physical sector 1, whose entries give
 * the start as cylinder / head / sector of the image's geometry. The FAT
 * itself is addressed in its own logical sectors (a PC-98 hard disk with
 * 256-byte sectors often has a FAT with 1024-byte ones).
 *
 * Changes are written so that a failure part way leaves at worst lost
 * clusters: data first, then the FAT, then the directory entry.
 */

#include "diskfs.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>

#define MAX_VOLUMES		16
#define DIRENT_SIZE		32

enum {
	LAYOUT_LINEAR,		/* header + sectors in order */
	LAYOUT_D88			/* sectors anywhere, through a map */
};

struct _dfsvolume {
	DFSIMAGE	*image;
	uint64_t	offset;			/* of the boot sector on the disk */
	char		name[17];
	uint32_t	bps;			/* bytes per logical sector */
	uint32_t	spc;
	uint32_t	clustersize;
	uint32_t	nfats;
	uint32_t	fatsectors;
	uint32_t	fatstart;		/* logical sectors from the boot sector */
	uint32_t	rootstart;
	uint32_t	rootentries;
	uint32_t	datastart;
	uint32_t	clusters;		/* data clusters, numbered 2 .. clusters + 1 */
	uint32_t	rootcluster;	/* FAT32 */
	uint32_t	fsinfo;			/* FAT32, logical sector or 0 */
	int			fattype;
	uint8_t		*fat;			/* the first FAT, in memory */
	uint32_t	fatbytes;
	uint8_t		*fatdirty;		/* per FAT sector */
	uint32_t	nextfree;
	int			fsinfodirty;
};

struct _dfsimage {
	int			fd;
	int			writable;
	int			layout;
	uint64_t	header;			/* LAYOUT_LINEAR */
	uint32_t	secsize;		/* physical */
	uint32_t	sectors;		/* geometry: sectors per track */
	uint32_t	surfaces;
	uint64_t	*secmap;		/* LAYOUT_D88: file offset of each sector */
	uint32_t	secmapcount;
	int			isfloppy;
	int			nvolumes;
	DFSVOLUME	volumes[MAX_VOLUMES];
};

static uint16_t le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put16(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

static void put32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static int is_pow2(uint32_t v)
{
	return v != 0 && (v & (v - 1)) == 0;
}

// ---- the disk

/* Reads beyond the end of the file give zeros: a new .hdd can be just its
 * header, growing as it is written. */
static int file_read(int fd, uint64_t pos, void *buf, size_t size)
{
	uint8_t *p = buf;
	while (size) {
		ssize_t r = pread(fd, p, size, (off_t)pos);
		if (r < 0) {
			return DFS_EIO;
		}
		if (r == 0) {
			memset(p, 0, size);
			break;
		}
		p += r;
		pos += (uint64_t)r;
		size -= (size_t)r;
	}
	return DFS_OK;
}

static int file_write(int fd, uint64_t pos, const void *buf, size_t size)
{
	const uint8_t *p = buf;
	while (size) {
		ssize_t r = pwrite(fd, p, size, (off_t)pos);
		if (r <= 0) {
			return DFS_EIO;
		}
		p += r;
		pos += (uint64_t)r;
		size -= (size_t)r;
	}
	return DFS_OK;
}

static int disk_io(DFSIMAGE *image, uint64_t pos, void *buf, size_t size, int write)
{
	if (write && !image->writable) {
		return DFS_EROFS;
	}
	if (image->layout == LAYOUT_LINEAR) {
		return write ? file_write(image->fd, image->header + pos, buf, size)
		             : file_read(image->fd, image->header + pos, buf, size);
	}
	uint8_t *p = buf;
	while (size) {
		uint64_t sector = pos / image->secsize;
		uint32_t inner = (uint32_t)(pos % image->secsize);
		size_t chunk = image->secsize - inner;
		if (chunk > size) {
			chunk = size;
		}
		if (sector >= image->secmapcount) {
			return DFS_EIO;
		}
		uint64_t at = image->secmap[sector] + inner;
		int r = write ? file_write(image->fd, at, p, chunk) : file_read(image->fd, at, p, chunk);
		if (r != DFS_OK) {
			return r;
		}
		p += chunk;
		pos += chunk;
		size -= chunk;
	}
	return DFS_OK;
}

static int disk_read(DFSIMAGE *image, uint64_t pos, void *buf, size_t size)
{
	return disk_io(image, pos, buf, size, 0);
}

static int disk_write(DFSIMAGE *image, uint64_t pos, const void *buf, size_t size)
{
	return disk_io(image, pos, (void *)buf, size, 1);
}

// ---- image formats

static const char *extension(const char *path)
{
	const char *slash = strrchr(path, '/');
	const char *dot = strrchr(path, '.');
	return (dot && (!slash || dot > slash)) ? dot + 1 : "";
}

static int ext_is(const char *ext, const char *list)
{
	/* list: "hdd|nhd|..." */
	size_t n = strlen(ext);
	const char *p = list;
	while (*p) {
		const char *bar = strchr(p, '|');
		size_t len = bar ? (size_t)(bar - p) : strlen(p);
		if (len == n && strncasecmp(p, ext, n) == 0) {
			return 1;
		}
		if (!bar) {
			break;
		}
		p = bar + 1;
	}
	return 0;
}

static int open_hdd(DFSIMAGE *image, const char *ext)
{
	uint8_t h[0x200];
	if (file_read(image->fd, 0, h, sizeof(h)) != DFS_OK) {
		return DFS_EIO;
	}
	if (ext_is(ext, "hdd")) {				/* Virtual98 */
		if (memcmp(h, "VHD", 3) != 0) {
			return DFS_EFORMAT;
		}
		image->header = 0xdc;
		image->secsize = le16(h + 0x8e);
		image->sectors = h[0x90];
		image->surfaces = h[0x91];
	}
	else if (ext_is(ext, "nhd")) {			/* T98-Next */
		if (memcmp(h, "T98HDDIMAGE.R0", 14) != 0) {
			return DFS_EFORMAT;
		}
		image->header = le32(h + 0x110);
		image->surfaces = le16(h + 0x118);
		image->sectors = le16(h + 0x11a);
		image->secsize = le16(h + 0x11c);
	}
	else if (ext_is(ext, "hdi")) {			/* Anex86 */
		image->header = le32(h + 8);
		image->secsize = le32(h + 16);
		image->sectors = le32(h + 20);
		image->surfaces = le32(h + 24);
	}
	else if (ext_is(ext, "thd")) {			/* T98 */
		image->header = 256;
		image->secsize = 256;
		image->sectors = 33;
		image->surfaces = 8;
	}
	else if (ext_is(ext, "slh")) {			/* SL9821 */
		if (memcmp(h, "HDIM", 4) != 0) {
			return DFS_EFORMAT;
		}
		image->header = 512;
		image->secsize = le32(h + 12);
		image->surfaces = le32(h + 20);
		image->sectors = le32(h + 24);
	}
	else {									/* hdn / hds: raw SCSI */
		image->header = 0;
		image->secsize = 512;
		image->sectors = 32;
		image->surfaces = 8;
	}
	if (!is_pow2(image->secsize) || image->secsize < 256 || image->secsize > 4096 ||
	    image->sectors == 0 || image->surfaces == 0) {
		return DFS_EFORMAT;
	}
	return DFS_OK;
}

static int open_d88(DFSIMAGE *image)
{
	uint8_t head[0x2b0];
	if (file_read(image->fd, 0, head, sizeof(head)) != DFS_OK) {
		return DFS_EIO;
	}
	if (head[0x1a] & 0x10) {
		image->writable = 0;			/* write protected */
	}
	uint32_t disksize = le32(head + 0x1c);
	uint32_t capacity = 164 * 64;
	image->secmap = calloc(capacity, sizeof(uint64_t));
	if (image->secmap == NULL) {
		return DFS_ENOMEM;
	}
	image->secsize = 0;
	for (int track = 0; track < 164; track++) {
		uint32_t pos = le32(head + 0x20 + track * 4);
		if (pos == 0 || pos >= disksize) {
			continue;
		}
		/* sectors of a track, ordered by their number R */
		uint64_t offsets[64];
		uint8_t numbers[64];
		uint32_t count = 0;
		uint32_t total = 1;
		while (count < total && count < 64) {
			uint8_t sec[16];
			if (file_read(image->fd, pos, sec, sizeof(sec)) != DFS_OK) {
				return DFS_EIO;
			}
			total = le16(sec + 4);
			uint32_t size = le16(sec + 14);
			if (image->secsize == 0) {
				image->secsize = size;
			}
			if (size != image->secsize || total > 64) {
				return DFS_EFORMAT;		/* mixed sector sizes: not a DOS disk */
			}
			offsets[count] = pos + 16;
			numbers[count] = sec[2];
			count++;
			pos += 16 + size;
		}
		for (uint32_t i = 1; i < count; i++) {
			for (uint32_t j = i; j > 0 && numbers[j - 1] > numbers[j]; j--) {
				uint8_t n = numbers[j]; numbers[j] = numbers[j - 1]; numbers[j - 1] = n;
				uint64_t o = offsets[j]; offsets[j] = offsets[j - 1]; offsets[j - 1] = o;
			}
		}
		for (uint32_t i = 0; i < count && image->secmapcount < capacity; i++) {
			image->secmap[image->secmapcount++] = offsets[i];
		}
	}
	if (image->secmapcount == 0 || !is_pow2(image->secsize)) {
		return DFS_EFORMAT;
	}
	image->layout = LAYOUT_D88;
	return DFS_OK;
}

static int open_fdd(DFSIMAGE *image, const char *ext)
{
	image->isfloppy = 1;
	if (ext_is(ext, "d88|88d|d98|98d")) {
		return open_d88(image);
	}
	if (ext_is(ext, "fdi")) {				/* Anex86 */
		uint8_t h[32];
		if (file_read(image->fd, 0, h, sizeof(h)) != DFS_OK) {
			return DFS_EIO;
		}
		image->header = le32(h + 8);
	}
	else {
		image->header = 0;
	}
	image->secsize = 1024;
	return DFS_OK;
}

// ---- volumes

static int load_fat(DFSVOLUME *v)
{
	v->fatbytes = v->fatsectors * v->bps;
	v->fat = malloc(v->fatbytes);
	v->fatdirty = calloc(v->fatsectors, 1);
	if (v->fat == NULL || v->fatdirty == NULL) {
		return DFS_ENOMEM;
	}
	return disk_read(v->image, v->offset + (uint64_t)v->fatstart * v->bps, v->fat, v->fatbytes);
}

/* Sets up a volume from the boot sector at pos, if it has a FAT BPB. */
static int try_volume(DFSIMAGE *image, uint64_t pos, const char *name)
{
	if (image->nvolumes >= MAX_VOLUMES) {
		return DFS_EINVAL;
	}
	uint8_t b[64];
	if (disk_read(image, pos, b, sizeof(b)) != DFS_OK) {
		return DFS_EIO;
	}
	uint32_t bps = le16(b + 0x0b);
	uint32_t spc = b[0x0d];
	uint32_t reserved = le16(b + 0x0e);
	uint32_t nfats = b[0x10];
	uint32_t rootentries = le16(b + 0x11);
	uint32_t total = le16(b + 0x13);
	uint32_t fatsectors = le16(b + 0x16);
	if (total == 0) {
		total = le32(b + 0x20);
	}
	if (fatsectors == 0) {
		fatsectors = le32(b + 0x24);
	}
	if (!is_pow2(bps) || bps < 128 || bps > 4096 || !is_pow2(spc) || reserved == 0 ||
	    nfats == 0 || nfats > 4 || fatsectors == 0 || total == 0 || b[0x15] < 0xf0) {
		return DFS_EFORMAT;
	}
	DFSVOLUME *v = &image->volumes[image->nvolumes];
	memset(v, 0, sizeof(*v));
	v->image = image;
	v->offset = pos;
	v->bps = bps;
	v->spc = spc;
	v->clustersize = bps * spc;
	v->nfats = nfats;
	v->fatsectors = fatsectors;
	v->fatstart = reserved;
	v->rootstart = reserved + nfats * fatsectors;
	v->rootentries = rootentries;
	v->datastart = v->rootstart + (rootentries * DIRENT_SIZE + bps - 1) / bps;
	if (total <= v->datastart) {
		return DFS_EFORMAT;
	}
	v->clusters = (total - v->datastart) / spc;
	if (v->clusters < 4085) {
		v->fattype = 12;
	}
	else if (v->clusters < 65525) {
		v->fattype = 16;
	}
	else {
		v->fattype = 32;
		v->rootcluster = le32(b + 0x2c);
		v->fsinfo = le16(b + 0x30);
		if (v->fsinfo == 0xffff || v->fsinfo >= reserved) {
			v->fsinfo = 0;
		}
	}
	if (v->fattype != 32 && rootentries == 0) {
		return DFS_EFORMAT;
	}
	/* the FAT must hold all clusters */
	uint64_t needed = (uint64_t)(v->clusters + 2) * (v->fattype == 12 ? 3 : v->fattype / 4) / 2;
	if (needed > (uint64_t)fatsectors * bps) {
		return DFS_EFORMAT;
	}
	snprintf(v->name, sizeof(v->name), "%s", name ? name : "");
	int r = load_fat(v);
	if (r != DFS_OK) {
		free(v->fat);
		free(v->fatdirty);
		return r;
	}
	v->nextfree = 2;
	image->nvolumes++;
	return DFS_OK;
}

static void trim_name(char *s)
{
	size_t n = strlen(s);
	while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\0')) {
		s[--n] = '\0';
	}
}

/* PC-98: physical sector 1 has 16 entries of 32 bytes. */
static void find_pc98_partitions(DFSIMAGE *image)
{
	uint8_t table[512];
	if (disk_read(image, image->secsize, table, sizeof(table)) != DFS_OK) {
		return;
	}
	for (int i = 0; i < 16; i++) {
		const uint8_t *e = table + i * 32;
		if (e[0] == 0 && e[1] == 0) {
			continue;
		}
		uint32_t sector = e[8];
		uint32_t head = e[9];
		uint32_t cylinder = le16(e + 10);
		uint64_t lba = ((uint64_t)cylinder * image->surfaces + head) * image->sectors + sector;
		char name[17];
		memcpy(name, e + 16, 16);
		name[16] = '\0';
		trim_name(name);
		try_volume(image, lba * image->secsize, name);
	}
}

/* PC/AT: a master boot record (some PC-9821 disks, or images from elsewhere) */
static void find_at_partitions(DFSIMAGE *image)
{
	uint8_t mbr[512];
	if (disk_read(image, 0, mbr, sizeof(mbr)) != DFS_OK || mbr[510] != 0x55 || mbr[511] != 0xaa) {
		return;
	}
	for (int i = 0; i < 4; i++) {
		const uint8_t *e = mbr + 0x1be + i * 16;
		uint8_t type = e[4];
		if (type == 0x01 || type == 0x04 || type == 0x06 || type == 0x0b || type == 0x0c || type == 0x0e) {
			try_volume(image, (uint64_t)le32(e + 8) * 512, NULL);
		}
	}
}

DFSIMAGE *dfs_open(const char *path, int writable, int *error)
{
	int err = DFS_OK;
	DFSIMAGE *image = calloc(1, sizeof(DFSIMAGE));
	if (image == NULL) {
		err = DFS_ENOMEM;
		goto failed;
	}
	image->fd = open(path, writable ? O_RDWR : O_RDONLY);
	if (image->fd < 0 && writable) {
		image->fd = open(path, O_RDONLY);
		writable = 0;
	}
	if (image->fd < 0) {
		err = DFS_EIO;
		free(image);
		image = NULL;
		goto failed;
	}
	image->writable = writable;
	image->layout = LAYOUT_LINEAR;

	const char *ext = extension(path);
	if (ext_is(ext, "hdd|nhd|hdi|thd|slh|hdn|hds")) {
		err = open_hdd(image, ext);
		if (err == DFS_OK) {
			find_pc98_partitions(image);
			if (image->nvolumes == 0) {
				find_at_partitions(image);
			}
			if (image->nvolumes == 0) {
				try_volume(image, 0, NULL);		/* no partitions */
			}
		}
	}
	else if (ext_is(ext, "vhd")) {
		err = DFS_EFORMAT;					/* Virtual PC: not supported */
	}
	else {
		err = open_fdd(image, ext);
		if (err == DFS_OK) {
			try_volume(image, 0, NULL);
		}
	}
	if (err == DFS_OK && image->nvolumes == 0) {
		err = DFS_EFORMAT;
	}
	if (err != DFS_OK) {
		dfs_close(image);
		image = NULL;
	}
failed:
	if (error) {
		*error = err;
	}
	return image;
}

void dfs_close(DFSIMAGE *image)
{
	if (image == NULL) {
		return;
	}
	for (int i = 0; i < image->nvolumes; i++) {
		free(image->volumes[i].fat);
		free(image->volumes[i].fatdirty);
	}
	if (image->fd >= 0) {
		if (image->writable) {
			fsync(image->fd);
		}
		close(image->fd);
	}
	free(image->secmap);
	free(image);
}

int dfs_iswritable(const DFSIMAGE *image)
{
	return image->writable;
}

int dfs_volumecount(const DFSIMAGE *image)
{
	return image->nvolumes;
}

DFSVOLUME *dfs_volume(DFSIMAGE *image, int index)
{
	return (index >= 0 && index < image->nvolumes) ? &image->volumes[index] : NULL;
}

// ---- the FAT

static uint32_t fat_get(const DFSVOLUME *v, uint32_t n)
{
	const uint8_t *f = v->fat;
	switch (v->fattype) {
		case 12: {
			uint32_t at = n + n / 2;
			if (at + 1 >= v->fatbytes) {
				return 0x0fffffff;
			}
			uint32_t w = le16(f + at);
			return (n & 1) ? (w >> 4) : (w & 0xfff);
		}
		case 16:
			return (n * 2 + 1 < v->fatbytes) ? le16(f + n * 2) : 0x0fffffff;
		default:
			return (n * 4 + 3 < v->fatbytes) ? (le32(f + n * 4) & 0x0fffffff) : 0x0fffffff;
	}
}

static void fat_dirty(DFSVOLUME *v, uint32_t at, uint32_t len)
{
	for (uint32_t s = at / v->bps; s <= (at + len - 1) / v->bps && s < v->fatsectors; s++) {
		v->fatdirty[s] = 1;
	}
}

static void fat_set(DFSVOLUME *v, uint32_t n, uint32_t value)
{
	uint8_t *f = v->fat;
	v->fsinfodirty = 1;
	switch (v->fattype) {
		case 12: {
			uint32_t at = n + n / 2;
			uint32_t w = le16(f + at);
			w = (n & 1) ? ((w & 0x000f) | ((value & 0xfff) << 4)) : ((w & 0xf000) | (value & 0xfff));
			put16(f + at, w);
			fat_dirty(v, at, 2);
			break;
		}
		case 16:
			put16(f + n * 2, value);
			fat_dirty(v, n * 2, 2);
			break;
		default:
			put32(f + n * 4, (le32(f + n * 4) & 0xf0000000) | (value & 0x0fffffff));
			fat_dirty(v, n * 4, 4);
			break;
	}
}

static uint32_t fat_eoc(const DFSVOLUME *v)
{
	return v->fattype == 12 ? 0xfff : v->fattype == 16 ? 0xffff : 0x0fffffff;
}

static int is_eoc(const DFSVOLUME *v, uint32_t value)
{
	return value >= (fat_eoc(v) & ~7u);
}

static int valid_cluster(const DFSVOLUME *v, uint32_t c)
{
	return c >= 2 && c < v->clusters + 2;
}

static uint32_t count_free(const DFSVOLUME *v);

/* Every copy of the FAT gets the changed sectors. */
static int fat_flush(DFSVOLUME *v)
{
	for (uint32_t s = 0; s < v->fatsectors; s++) {
		if (!v->fatdirty[s]) {
			continue;
		}
		for (uint32_t copy = 0; copy < v->nfats; copy++) {
			uint64_t pos = v->offset + ((uint64_t)v->fatstart + copy * v->fatsectors + s) * v->bps;
			int r = disk_write(v->image, pos, v->fat + s * v->bps, v->bps);
			if (r != DFS_OK) {
				return r;
			}
		}
		v->fatdirty[s] = 0;
	}
	if (v->fattype == 32 && v->fsinfo && v->fsinfodirty) {
		/* the free count and where to look next, as hints for DOS */
		uint8_t hint[8];
		put32(hint, count_free(v));
		put32(hint + 4, v->nextfree);
		uint64_t pos = v->offset + (uint64_t)v->fsinfo * v->bps + 0x1e8;
		uint8_t sig[4];
		if (disk_read(v->image, pos - 0x1e8 + 0x1e4, sig, 4) == DFS_OK && le32(sig) == 0x61417272) {
			int r = disk_write(v->image, pos, hint, sizeof(hint));
			if (r != DFS_OK) {
				return r;
			}
		}
		v->fsinfodirty = 0;
	}
	return DFS_OK;
}

static uint32_t count_free(const DFSVOLUME *v)
{
	uint32_t n = 0;
	for (uint32_t c = 2; c < v->clusters + 2; c++) {
		if (fat_get(v, c) == 0) {
			n++;
		}
	}
	return n;
}

static void free_chain(DFSVOLUME *v, uint32_t c)
{
	uint32_t guard = v->clusters;
	while (valid_cluster(v, c) && guard--) {
		uint32_t next = fat_get(v, c);
		fat_set(v, c, 0);
		if (c < v->nextfree) {
			v->nextfree = c;
		}
		if (is_eoc(v, next) || next == 0) {
			break;
		}
		c = next;
	}
}

/* A chain of count clusters (linked, ended), or 0 when there is no room.
 * Nothing is changed when it fails. */
static uint32_t alloc_chain(DFSVOLUME *v, uint32_t count)
{
	if (count == 0) {
		return 0;
	}
	uint32_t *list = malloc(count * sizeof(uint32_t));
	if (list == NULL) {
		return 0;
	}
	uint32_t found = 0;
	uint32_t c = valid_cluster(v, v->nextfree) ? v->nextfree : 2;
	for (uint32_t tried = 0; tried < v->clusters && found < count; tried++) {
		if (fat_get(v, c) == 0) {
			list[found++] = c;
		}
		c = (c + 1 < v->clusters + 2) ? c + 1 : 2;
	}
	if (found < count) {
		free(list);
		return 0;
	}
	for (uint32_t i = 0; i < count; i++) {
		fat_set(v, list[i], (i + 1 < count) ? list[i + 1] : fat_eoc(v));
	}
	uint32_t first = list[0];
	v->nextfree = list[count - 1] + 1;
	free(list);
	return first;
}

static uint64_t cluster_pos(const DFSVOLUME *v, uint32_t c)
{
	return v->offset + ((uint64_t)v->datastart + (uint64_t)(c - 2) * v->spc) * v->bps;
}

void dfs_volumeinfo(DFSVOLUME *v, DFSVOLUMEINFO *info)
{
	memset(info, 0, sizeof(*info));
	snprintf(info->name, sizeof(info->name), "%s", v->name);
	info->fattype = v->fattype;
	info->totalbytes = (uint64_t)v->clusters * v->clustersize;
	info->freebytes = (uint64_t)count_free(v) * v->clustersize;
	/* the label in the boot sector (the one in the root directory is not
	 * looked for) */
	uint8_t boot[0x60];
	if (disk_read(v->image, v->offset, boot, sizeof(boot)) == DFS_OK) {
		const uint8_t *l = (v->fattype == 32) ? boot + 0x47 : boot + 0x2b;
		uint8_t sig = (v->fattype == 32) ? boot[0x42] : boot[0x26];
		if (sig == 0x29) {
			memcpy(info->label, l, 11);
			info->label[11] = '\0';
			trim_name(info->label);
			if (strcmp(info->label, "NO NAME") == 0) {
				info->label[0] = '\0';
			}
		}
	}
}

// ---- directories

typedef struct {
	uint8_t		*data;
	uint32_t	size;
	uint32_t	*clusters;		/* NULL for the fixed root */
	uint32_t	nclusters;
	uint64_t	rootpos;
} DIRBUF;

static void dir_free(DIRBUF *d)
{
	free(d->data);
	free(d->clusters);
	memset(d, 0, sizeof(*d));
}

static int dir_load(DFSVOLUME *v, uint32_t dir, DIRBUF *d)
{
	memset(d, 0, sizeof(*d));
	if (dir == 0 && v->fattype != 32) {
		d->size = v->rootentries * DIRENT_SIZE;
		d->rootpos = v->offset + (uint64_t)v->rootstart * v->bps;
		d->data = malloc(d->size);
		if (d->data == NULL) {
			return DFS_ENOMEM;
		}
		return disk_read(v->image, d->rootpos, d->data, d->size);
	}
	uint32_t c = (dir == 0) ? v->rootcluster : dir;
	uint32_t capacity = 0;
	while (valid_cluster(v, c)) {
		if (d->nclusters >= v->clusters) {
			dir_free(d);
			return DFS_EFORMAT;		/* a loop */
		}
		if (d->nclusters == capacity) {
			capacity = capacity ? capacity * 2 : 4;
			uint32_t *list = realloc(d->clusters, capacity * sizeof(uint32_t));
			uint8_t *data = realloc(d->data, (size_t)capacity * v->clustersize);
			if (list == NULL || data == NULL) {
				d->clusters = list ? list : d->clusters;
				d->data = data ? data : d->data;
				dir_free(d);
				return DFS_ENOMEM;
			}
			d->clusters = list;
			d->data = data;
		}
		int r = disk_read(v->image, cluster_pos(v, c), d->data + d->size, v->clustersize);
		if (r != DFS_OK) {
			dir_free(d);
			return r;
		}
		d->clusters[d->nclusters++] = c;
		d->size += v->clustersize;
		uint32_t next = fat_get(v, c);
		if (is_eoc(v, next)) {
			break;
		}
		c = next;
	}
	if (d->nclusters == 0) {
		dir_free(d);
		return DFS_EFORMAT;
	}
	return DFS_OK;
}

static int dir_writeentry(DFSVOLUME *v, const DIRBUF *d, uint32_t index)
{
	uint32_t at = index * DIRENT_SIZE;
	uint64_t pos;
	if (d->clusters == NULL) {
		pos = d->rootpos + at;
	}
	else {
		pos = cluster_pos(v, d->clusters[at / v->clustersize]) + at % v->clustersize;
	}
	return disk_write(v->image, pos, d->data + at, DIRENT_SIZE);
}

/* One more (zeroed) cluster at the end of a subdirectory. */
static int dir_extend(DFSVOLUME *v, DIRBUF *d)
{
	if (d->clusters == NULL) {
		return DFS_EDIRFULL;
	}
	uint32_t c = alloc_chain(v, 1);
	if (c == 0) {
		return DFS_ENOSPC;
	}
	uint8_t *zero = calloc(1, v->clustersize);
	uint32_t *list = realloc(d->clusters, (d->nclusters + 1) * sizeof(uint32_t));
	uint8_t *data = list ? realloc(d->data, d->size + v->clustersize) : NULL;
	if (zero == NULL || list == NULL || data == NULL) {
		free(zero);
		if (list) {
			d->clusters = list;
		}
		fat_set(v, c, 0);
		return DFS_ENOMEM;
	}
	d->clusters = list;
	d->data = data;
	int r = disk_write(v->image, cluster_pos(v, c), zero, v->clustersize);
	free(zero);
	if (r != DFS_OK) {
		fat_set(v, c, 0);
		return r;
	}
	fat_set(v, d->clusters[d->nclusters - 1], c);
	d->clusters[d->nclusters++] = c;
	memset(d->data + d->size, 0, v->clustersize);
	d->size += v->clustersize;
	return fat_flush(v);
}

static int entry_is_end(const uint8_t *e)
{
	return e[0] == 0x00;
}

static int entry_is_free(const uint8_t *e)
{
	return e[0] == 0x00 || e[0] == 0xe5;
}

static int entry_is_listed(const uint8_t *e)
{
	if (entry_is_free(e) || e[11] == 0x0f || (e[11] & DFS_ATTR_VOLUME)) {
		return 0;
	}
	return e[0] != '.';
}

static uint32_t entry_cluster(const DFSVOLUME *v, const uint8_t *e)
{
	uint32_t c = le16(e + 26);
	if (v->fattype == 32) {
		c |= (uint32_t)le16(e + 20) << 16;
	}
	return c;
}

static void entry_setcluster(const DFSVOLUME *v, uint8_t *e, uint32_t c)
{
	put16(e + 26, c);
	put16(e + 20, v->fattype == 32 ? (c >> 16) : 0);
}

static void stored_name(const uint8_t *e, uint8_t name[11])
{
	memcpy(name, e, 11);
	if (name[0] == 0x05) {
		name[0] = 0xe5;
	}
}

static void entry_setname(uint8_t *e, const uint8_t name[11])
{
	memcpy(e, name, 11);
	if (e[0] == 0xe5) {
		e[0] = 0x05;
	}
}

void dfs_displayname(const uint8_t name[11], char *display)
{
	int n = 0;
	for (int i = 0; i < 8 && name[i] != ' '; i++) {
		display[n++] = (char)name[i];
	}
	/* trailing spaces only: a space inside a name is kept */
	while (n > 0 && display[n - 1] == ' ') {
		n--;
	}
	int extlen = 3;
	while (extlen > 0 && name[8 + extlen - 1] == ' ') {
		extlen--;
	}
	if (extlen > 0) {
		display[n++] = '.';
		for (int i = 0; i < extlen; i++) {
			display[n++] = (char)name[8 + i];
		}
	}
	display[n] = '\0';
}

static void make_entry(const DFSVOLUME *v, const uint8_t *e, DFSENTRY *out)
{
	memset(out, 0, sizeof(*out));
	stored_name(e, out->name);
	dfs_displayname(out->name, out->display);
	out->attr = e[11];
	out->size = le32(e + 28);
	out->cluster = entry_cluster(v, e);
	out->time = le16(e + 22);
	out->date = le16(e + 24);
}

/* Index of the entry with this name, or -1. */
static int dir_find(const DIRBUF *d, const uint8_t name[11])
{
	for (uint32_t i = 0; i < d->size / DIRENT_SIZE; i++) {
		const uint8_t *e = d->data + i * DIRENT_SIZE;
		if (entry_is_end(e)) {
			break;
		}
		if (entry_is_free(e) || e[11] == 0x0f || (e[11] & DFS_ATTR_VOLUME)) {
			continue;
		}
		uint8_t stored[11];
		stored_name(e, stored);
		if (memcmp(stored, name, 11) == 0) {
			return (int)i;
		}
	}
	return -1;
}

/* A free slot, extending the directory if needed. */
static int dir_freeslot(DFSVOLUME *v, DIRBUF *d, uint32_t *index)
{
	for (uint32_t i = 0; i < d->size / DIRENT_SIZE; i++) {
		if (entry_is_free(d->data + i * DIRENT_SIZE)) {
			*index = i;
			return DFS_OK;
		}
	}
	uint32_t i = d->size / DIRENT_SIZE;
	int r = dir_extend(v, d);
	if (r == DFS_OK) {
		*index = i;
	}
	return r;
}

/* Marks the long name parts just before an entry deleted, so that they do
 * not hang on to another one later. */
static int dir_droplongname(DFSVOLUME *v, DIRBUF *d, uint32_t index)
{
	while (index > 0) {
		uint8_t *e = d->data + (index - 1) * DIRENT_SIZE;
		if (e[0] == 0xe5 || e[11] != 0x0f) {
			break;
		}
		e[0] = 0xe5;
		int r = dir_writeentry(v, d, index - 1);
		if (r != DFS_OK) {
			return r;
		}
		index--;
	}
	return DFS_OK;
}

int dfs_listdir(DFSVOLUME *v, uint32_t dir, DFSENTRY **entries, int *count)
{
	*entries = NULL;
	*count = 0;
	DIRBUF d;
	int r = dir_load(v, dir, &d);
	if (r != DFS_OK) {
		return r;
	}
	uint32_t total = d.size / DIRENT_SIZE;
	DFSENTRY *list = calloc(total ? total : 1, sizeof(DFSENTRY));
	if (list == NULL) {
		dir_free(&d);
		return DFS_ENOMEM;
	}
	int n = 0;
	for (uint32_t i = 0; i < total; i++) {
		const uint8_t *e = d.data + i * DIRENT_SIZE;
		if (entry_is_end(e)) {
			break;
		}
		if (entry_is_listed(e)) {
			make_entry(v, e, &list[n++]);
		}
	}
	dir_free(&d);
	*entries = list;
	*count = n;
	return DFS_OK;
}

int dfs_find(DFSVOLUME *v, uint32_t dir, const uint8_t name[11], DFSENTRY *entry)
{
	DIRBUF d;
	int r = dir_load(v, dir, &d);
	if (r != DFS_OK) {
		return r;
	}
	int index = dir_find(&d, name);
	if (index < 0) {
		r = DFS_ENOENT;
	}
	else if (entry) {
		make_entry(v, d.data + index * DIRENT_SIZE, entry);
	}
	dir_free(&d);
	return r;
}

// ---- files

int dfs_readfile(DFSVOLUME *v, const DFSENTRY *entry, uint8_t **data, uint32_t *size)
{
	*data = NULL;
	*size = 0;
	if (entry->attr & DFS_ATTR_DIRECTORY) {
		return DFS_EISDIR;
	}
	uint8_t *buf = malloc(entry->size ? entry->size : 1);
	if (buf == NULL) {
		return DFS_ENOMEM;
	}
	uint32_t done = 0;
	uint32_t c = entry->cluster;
	while (done < entry->size) {
		if (!valid_cluster(v, c)) {
			free(buf);
			return DFS_EFORMAT;
		}
		uint32_t chunk = entry->size - done;
		if (chunk > v->clustersize) {
			chunk = v->clustersize;
		}
		int r = disk_read(v->image, cluster_pos(v, c), buf + done, chunk);
		if (r != DFS_OK) {
			free(buf);
			return r;
		}
		done += chunk;
		c = fat_get(v, c);
	}
	*data = buf;
	*size = entry->size;
	return DFS_OK;
}

static int write_chain(DFSVOLUME *v, uint32_t first, const uint8_t *data, uint32_t size)
{
	uint8_t *last = NULL;
	uint32_t c = first;
	uint32_t done = 0;
	int r = DFS_OK;
	while (done < size && r == DFS_OK) {
		uint32_t chunk = size - done;
		if (chunk >= v->clustersize) {
			r = disk_write(v->image, cluster_pos(v, c), data + done, v->clustersize);
			done += v->clustersize;
		}
		else {
			/* the rest of the last cluster is zeroed */
			last = calloc(1, v->clustersize);
			if (last == NULL) {
				return DFS_ENOMEM;
			}
			memcpy(last, data + done, chunk);
			r = disk_write(v->image, cluster_pos(v, c), last, v->clustersize);
			done += chunk;
		}
		c = fat_get(v, c);
	}
	free(last);
	return r;
}

static int check_writable(const DFSVOLUME *v)
{
	return v->image->writable ? DFS_OK : DFS_EROFS;
}

int dfs_writefile(DFSVOLUME *v, uint32_t dir, const uint8_t name[11],
                  const void *data, uint32_t size, uint16_t date, uint16_t time)
{
	int r = check_writable(v);
	if (r != DFS_OK) {
		return r;
	}
	DIRBUF d;
	r = dir_load(v, dir, &d);
	if (r != DFS_OK) {
		return r;
	}
	int index = dir_find(&d, name);
	uint32_t old = 0;
	if (index >= 0) {
		uint8_t *e = d.data + index * DIRENT_SIZE;
		if (e[11] & DFS_ATTR_DIRECTORY) {
			dir_free(&d);
			return DFS_EISDIR;
		}
		old = entry_cluster(v, e);
	}
	uint32_t count = (size + v->clustersize - 1) / v->clustersize;
	uint32_t first = 0;
	if (count) {
		first = alloc_chain(v, count);
		if (first == 0 && old) {
			/* not enough room for both: let the old one go first (the
			 * entry is emptied before, so it never points at free space) */
			uint8_t *e = d.data + index * DIRENT_SIZE;
			entry_setcluster(v, e, 0);
			put32(e + 28, 0);
			r = dir_writeentry(v, &d, (uint32_t)index);
			if (r != DFS_OK) {
				dir_free(&d);
				return r;
			}
			free_chain(v, old);
			old = 0;
			first = alloc_chain(v, count);
		}
		if (first == 0) {
			fat_flush(v);
			dir_free(&d);
			return DFS_ENOSPC;
		}
		r = write_chain(v, first, data, size);
		if (r != DFS_OK) {
			free_chain(v, first);
			fat_flush(v);
			dir_free(&d);
			return r;
		}
	}
	r = fat_flush(v);
	uint32_t slot = 0;
	if (r == DFS_OK) {
		if (index >= 0) {
			slot = (uint32_t)index;
		}
		else {
			r = dir_freeslot(v, &d, &slot);
		}
	}
	if (r != DFS_OK) {
		if (first) {
			free_chain(v, first);
			fat_flush(v);
		}
		dir_free(&d);
		return r;
	}
	uint8_t *e = d.data + slot * DIRENT_SIZE;
	if (index < 0) {
		memset(e, 0, DIRENT_SIZE);
		entry_setname(e, name);
		e[11] = DFS_ATTR_ARCHIVE;
		put16(e + 14, time);		/* created */
		put16(e + 16, date);
	}
	else {
		e[11] |= DFS_ATTR_ARCHIVE;
	}
	put16(e + 18, date);			/* accessed */
	put16(e + 22, time);
	put16(e + 24, date);
	entry_setcluster(v, e, first);
	put32(e + 28, size);
	r = dir_writeentry(v, &d, slot);
	if (r == DFS_OK && old) {
		free_chain(v, old);
		r = fat_flush(v);
	}
	dir_free(&d);
	return r;
}

int dfs_mkdir(DFSVOLUME *v, uint32_t dir, const uint8_t name[11],
              uint16_t date, uint16_t time, uint32_t *cluster)
{
	int r = check_writable(v);
	if (r != DFS_OK) {
		return r;
	}
	DIRBUF d;
	r = dir_load(v, dir, &d);
	if (r != DFS_OK) {
		return r;
	}
	if (dir_find(&d, name) >= 0) {
		dir_free(&d);
		return DFS_EEXIST;
	}
	uint32_t c = alloc_chain(v, 1);
	if (c == 0) {
		dir_free(&d);
		return DFS_ENOSPC;
	}
	uint8_t *data = calloc(1, v->clustersize);
	if (data == NULL) {
		fat_set(v, c, 0);
		dir_free(&d);
		return DFS_ENOMEM;
	}
	static const uint8_t dot[11] = {'.', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '};
	static const uint8_t dotdot[11] = {'.', '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '};
	uint8_t *e = data;
	memcpy(e, dot, 11);
	e[11] = DFS_ATTR_DIRECTORY;
	put16(e + 22, time);
	put16(e + 24, date);
	entry_setcluster(v, e, c);
	e += DIRENT_SIZE;
	memcpy(e, dotdot, 11);
	e[11] = DFS_ATTR_DIRECTORY;
	put16(e + 22, time);
	put16(e + 24, date);
	entry_setcluster(v, e, (dir == v->rootcluster) ? 0 : dir);
	r = disk_write(v->image, cluster_pos(v, c), data, v->clustersize);
	free(data);
	if (r == DFS_OK) {
		r = fat_flush(v);
	}
	uint32_t slot = 0;
	if (r == DFS_OK) {
		r = dir_freeslot(v, &d, &slot);
	}
	if (r != DFS_OK) {
		free_chain(v, c);
		fat_flush(v);
		dir_free(&d);
		return r;
	}
	e = d.data + slot * DIRENT_SIZE;
	memset(e, 0, DIRENT_SIZE);
	entry_setname(e, name);
	e[11] = DFS_ATTR_DIRECTORY;
	put16(e + 14, time);
	put16(e + 16, date);
	put16(e + 18, date);
	put16(e + 22, time);
	put16(e + 24, date);
	entry_setcluster(v, e, c);
	r = dir_writeentry(v, &d, slot);
	dir_free(&d);
	if (r == DFS_OK && cluster) {
		*cluster = c;
	}
	return r;
}

static int dir_isempty(DFSVOLUME *v, uint32_t c)
{
	DFSENTRY *entries;
	int count;
	int r = dfs_listdir(v, c, &entries, &count);
	free(entries);
	return (r == DFS_OK) ? (count == 0) : r;
}

int dfs_remove(DFSVOLUME *v, uint32_t dir, const uint8_t name[11])
{
	int r = check_writable(v);
	if (r != DFS_OK) {
		return r;
	}
	DIRBUF d;
	r = dir_load(v, dir, &d);
	if (r != DFS_OK) {
		return r;
	}
	int index = dir_find(&d, name);
	if (index < 0) {
		dir_free(&d);
		return DFS_ENOENT;
	}
	uint8_t *e = d.data + index * DIRENT_SIZE;
	uint32_t c = entry_cluster(v, e);
	if (e[11] & DFS_ATTR_DIRECTORY) {
		int empty = dir_isempty(v, c);
		if (empty != 1) {
			dir_free(&d);
			return empty == 0 ? DFS_ENOTEMPTY : empty;
		}
	}
	e[0] = 0xe5;
	r = dir_writeentry(v, &d, (uint32_t)index);
	if (r == DFS_OK) {
		r = dir_droplongname(v, &d, (uint32_t)index);
	}
	if (r == DFS_OK) {
		free_chain(v, c);
		r = fat_flush(v);
	}
	dir_free(&d);
	return r;
}

int dfs_rename(DFSVOLUME *v, uint32_t dir, const uint8_t name[11], const uint8_t newname[11])
{
	int r = check_writable(v);
	if (r != DFS_OK) {
		return r;
	}
	DIRBUF d;
	r = dir_load(v, dir, &d);
	if (r != DFS_OK) {
		return r;
	}
	int index = dir_find(&d, name);
	if (index < 0) {
		r = DFS_ENOENT;
	}
	else if (memcmp(name, newname, 11) != 0 && dir_find(&d, newname) >= 0) {
		r = DFS_EEXIST;
	}
	else {
		entry_setname(d.data + index * DIRENT_SIZE, newname);
		r = dir_writeentry(v, &d, (uint32_t)index);
		if (r == DFS_OK) {
			r = dir_droplongname(v, &d, (uint32_t)index);
		}
	}
	dir_free(&d);
	return r;
}

// ---- names

static int sjis_lead(uint8_t c)
{
	return (c >= 0x81 && c <= 0x9f) || (c >= 0xe0 && c <= 0xfc);
}

static int dos_allowed(uint8_t c)
{
	if (c < 0x20 || c == 0x7f) {
		return 0;
	}
	return strchr("\"*+,./:;<=>?[\\]| ", c) == NULL;
}

/* Copies up to max bytes of src[0..len) into dst, keeping double-byte
 * characters whole; returns the bytes written, *changed set if anything
 * was dropped or replaced. */
static int copy_part(const uint8_t *src, size_t len, uint8_t *dst, int max, int *changed)
{
	int n = 0;
	for (size_t i = 0; i < len; i++) {
		uint8_t c = src[i];
		if (sjis_lead(c) && i + 1 < len) {
			if (n + 2 > max) {
				*changed = 1;
				break;
			}
			dst[n++] = c;
			dst[n++] = src[++i];
			continue;
		}
		if (n + 1 > max) {
			*changed = 1;
			break;
		}
		if (c >= 'a' && c <= 'z') {
			c = (uint8_t)(c - 'a' + 'A');		/* case is not a change: DOS ignores it */
		}
		else if (!dos_allowed(c)) {
			if (c == ' ' || c == '.') {
				*changed = 1;
				continue;					/* dropped */
			}
			c = '_';
			*changed = 1;
		}
		dst[n++] = c;
	}
	return n;
}

int dfs_shortname(const char *longname, uint8_t name[11])
{
	const uint8_t *s = (const uint8_t *)longname;
	size_t len = strlen(longname);
	int changed = 0;
	while (len > 0 && (*s == '.' || *s == ' ')) {
		s++;
		len--;
		changed = 1;
	}
	while (len > 0 && (s[len - 1] == '.' || s[len - 1] == ' ')) {
		len--;
		changed = 1;
	}
	/* the last dot not inside a double-byte character */
	const uint8_t *dot = NULL;
	for (size_t i = 0; i < len; i++) {
		if (sjis_lead(s[i]) && i + 1 < len) {
			i++;
		}
		else if (s[i] == '.') {
			dot = s + i;
		}
	}
	memset(name, ' ', 11);
	size_t baselen = dot ? (size_t)(dot - s) : len;
	int n = copy_part(s, baselen, name, 8, &changed);
	if (dot) {
		copy_part(dot + 1, len - baselen - 1, name + 8, 3, &changed);
	}
	if (n == 0) {
		return DFS_EINVAL;
	}
	return changed ? 0 : 1;
}

int dfs_uniquename(DFSVOLUME *v, uint32_t dir, const char *longname, uint8_t name[11])
{
	int same = dfs_shortname(longname, name);
	if (same != 0) {
		return same;
	}
	DIRBUF d;
	int r = dir_load(v, dir, &d);
	if (r != DFS_OK) {
		return r;
	}
	uint8_t base[8];
	memcpy(base, name, 8);
	int baselen = 8;
	while (baselen > 0 && base[baselen - 1] == ' ') {
		baselen--;
	}
	for (int n = 1; n < 1000000; n++) {
		char tail[9];
		int taillen = snprintf(tail, sizeof(tail), "~%d", n);
		int keep = baselen;
		if (keep + taillen > 8) {
			keep = 8 - taillen;
		}
		/* do not cut a double-byte character in half */
		int i = 0;
		int cut = 0;
		while (i < keep) {
			int w = (sjis_lead(base[i]) && i + 1 < baselen) ? 2 : 1;
			if (i + w > keep) {
				break;
			}
			i += w;
			cut = i;
		}
		memset(name, ' ', 8);
		memcpy(name, base, (size_t)cut);
		memcpy(name + cut, tail, (size_t)taillen);
		if (dir_find(&d, name) < 0) {
			dir_free(&d);
			return 0;
		}
	}
	dir_free(&d);
	return DFS_EEXIST;
}

// ---- times

void dfs_dostime(int64_t unixtime, uint16_t *date, uint16_t *time)
{
	time_t t = (time_t)unixtime;
	struct tm tm;
	localtime_r(&t, &tm);
	int year = tm.tm_year + 1900;
	if (year < 1980) {
		*date = (0 << 9) | (1 << 5) | 1;
		*time = 0;
		return;
	}
	if (year > 2107) {
		year = 2107;
	}
	*date = (uint16_t)(((year - 1980) << 9) | ((tm.tm_mon + 1) << 5) | tm.tm_mday);
	*time = (uint16_t)((tm.tm_hour << 11) | (tm.tm_min << 5) | (tm.tm_sec / 2));
}

int64_t dfs_unixtime(uint16_t date, uint16_t time)
{
	struct tm tm;
	memset(&tm, 0, sizeof(tm));
	tm.tm_year = (date >> 9) + 80;
	tm.tm_mon = ((date >> 5) & 15) - 1;
	tm.tm_mday = date & 31;
	tm.tm_hour = time >> 11;
	tm.tm_min = (time >> 5) & 63;
	tm.tm_sec = (time & 31) * 2;
	tm.tm_isdst = -1;
	return (int64_t)mktime(&tm);
}

const char *dfs_strerror(int error)
{
	switch (error) {
		case DFS_OK:		return "OK";
		case DFS_EIO:		return "読み書きできませんでした";
		case DFS_EFORMAT:	return "対応していない形式です";
		case DFS_ENOSPC:	return "ディスクの空きが足りません";
		case DFS_EDIRFULL:	return "ルートフォルダがいっぱいです";
		case DFS_ENOENT:	return "見つかりません";
		case DFS_EEXIST:	return "同じ名前があります";
		case DFS_ENOTEMPTY:	return "フォルダが空ではありません";
		case DFS_EROFS:		return "書き込みできないディスクです";
		case DFS_EINVAL:	return "使えない名前です";
		case DFS_ENOMEM:	return "メモリが足りません";
		case DFS_EISDIR:	return "フォルダです";
		case DFS_ENOTDIR:	return "フォルダではありません";
		default:			return "エラー";
	}
}
