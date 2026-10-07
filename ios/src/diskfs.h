/**
 * @file	diskfs.h
 * @brief	Reading and writing files in PC-98 disk images (FAT12/16/32)
 *
 * Opens hard disk images (.hdd .nhd .hdi .thd .slh .hdn .hds) with their
 * PC-98 partition table (or a PC/AT one), and floppy images (raw, .fdi,
 * .d88), and lets the app list, read, write, rename and delete files on
 * the FAT volumes in them, without the guest.
 *
 * Directories are named by their first cluster (0 = the root) and entries
 * by their 11-byte 8.3 name as stored ("NAME    EXT", Shift_JIS). Every
 * call that changes something writes it to the image before returning.
 *
 * Not for an image the emulator is using at the same time: the guest caches
 * the FAT and directories, so it has to be reset after the image changed.
 * Plain C, no emulator code, so that it can be tested on the host
 * (tests/dfstool.c, tests/diskfs-test.sh).
 */

#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
	DFS_OK			= 0,
	DFS_EIO			= -1,
	DFS_EFORMAT		= -2,	/* not an image / file system this understands */
	DFS_ENOSPC		= -3,
	DFS_EDIRFULL	= -4,	/* the root directory of FAT12/16 has a fixed size */
	DFS_ENOENT		= -5,
	DFS_EEXIST		= -6,
	DFS_ENOTEMPTY	= -7,
	DFS_EROFS		= -8,
	DFS_EINVAL		= -9,
	DFS_ENOMEM		= -10,
	DFS_EISDIR		= -11,
	DFS_ENOTDIR		= -12
};

enum {
	DFS_ATTR_READONLY	= 0x01,
	DFS_ATTR_HIDDEN		= 0x02,
	DFS_ATTR_SYSTEM		= 0x04,
	DFS_ATTR_VOLUME		= 0x08,
	DFS_ATTR_DIRECTORY	= 0x10,
	DFS_ATTR_ARCHIVE	= 0x20
};

typedef struct _dfsimage	DFSIMAGE;
typedef struct _dfsvolume	DFSVOLUME;

typedef struct {
	uint8_t		name[11];		/* as stored, 0x05 for a leading 0xE5 undone */
	char		display[13];	/* "NAME.EXT", Shift_JIS, NUL-terminated */
	uint8_t		attr;
	uint32_t	size;
	uint32_t	cluster;
	uint16_t	date;			/* DOS format */
	uint16_t	time;
} DFSENTRY;

typedef struct {
	char		name[17];		/* the partition's name (Shift_JIS), or "" */
	char		label[12];		/* volume label, or "" */
	int			fattype;		/* 12, 16 or 32 */
	uint64_t	totalbytes;
	uint64_t	freebytes;
} DFSVOLUMEINFO;

/* Opens an image; the format is chosen by the file name's extension.
 * writable = 0 opens it read-only. Returns NULL and sets *error. */
DFSIMAGE *dfs_open(const char *path, int writable, int *error);
void dfs_close(DFSIMAGE *image);
int dfs_iswritable(const DFSIMAGE *image);

/* The FAT volumes found (a floppy has one, a hard disk one per partition). */
int dfs_volumecount(const DFSIMAGE *image);
DFSVOLUME *dfs_volume(DFSIMAGE *image, int index);
void dfs_volumeinfo(DFSVOLUME *volume, DFSVOLUMEINFO *info);

/* The entries of a directory, without "." / "..", volume labels and long
 * name parts. Free *entries with free(). */
int dfs_listdir(DFSVOLUME *volume, uint32_t dir, DFSENTRY **entries, int *count);
int dfs_find(DFSVOLUME *volume, uint32_t dir, const uint8_t name[11], DFSENTRY *entry);

/* Reads a whole file. Free *data with free(). */
int dfs_readfile(DFSVOLUME *volume, const DFSENTRY *entry, uint8_t **data, uint32_t *size);

/* Creates a file, or replaces the one with that name. */
int dfs_writefile(DFSVOLUME *volume, uint32_t dir, const uint8_t name[11],
                  const void *data, uint32_t size, uint16_t date, uint16_t time);
/* Creates a directory; *cluster (may be NULL) gets its cluster. */
int dfs_mkdir(DFSVOLUME *volume, uint32_t dir, const uint8_t name[11],
              uint16_t date, uint16_t time, uint32_t *cluster);
/* Deletes a file or an empty directory. */
int dfs_remove(DFSVOLUME *volume, uint32_t dir, const uint8_t name[11]);
int dfs_rename(DFSVOLUME *volume, uint32_t dir, const uint8_t name[11], const uint8_t newname[11]);

/* Makes an 8.3 name from a long one (Shift_JIS, NUL-terminated): upper
 * case, characters DOS does not allow replaced, cut to 8 + 3. Returns 1
 * when it is the same name, 0 when it had to be changed, DFS_EINVAL when
 * nothing is left. */
int dfs_shortname(const char *longname, uint8_t name[11]);
/* Like dfs_shortname, but when the name was changed, adds "~1", "~2" ...
 * until no entry in dir has it (a same name is left for the caller). */
int dfs_uniquename(DFSVOLUME *volume, uint32_t dir, const char *longname, uint8_t name[11]);
/* "NAME.EXT" from an 11-byte name (display needs 13 bytes). */
void dfs_displayname(const uint8_t name[11], char *display);

/* DOS date and time from seconds since 1970 (local time). */
void dfs_dostime(int64_t unixtime, uint16_t *date, uint16_t *time);
/* ... and back */
int64_t dfs_unixtime(uint16_t date, uint16_t time);

const char *dfs_strerror(int error);

#ifdef __cplusplus
}
#endif
