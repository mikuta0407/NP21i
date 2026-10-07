/*
 * dfstool: ios/src/diskfs.c on the host, for testing (tests/diskfs-test.sh)
 *
 *   dfstool <image> info
 *   dfstool <image> ls    <vol> [dir]
 *   dfstool <image> cat   <vol> <file>          (to stdout)
 *   dfstool <image> put   <vol> <dir> <hostfile> [name]
 *   dfstool <image> mkdir <vol> <dir>
 *   dfstool <image> rm    <vol> <path>
 *   dfstool <image> mv    <vol> <path> <newname>
 *
 * Paths use '/' and names as the listing shows them (Shift_JIS).
 */

#include "../ios/src/diskfs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static void fail(int r, const char *what)
{
	fprintf(stderr, "%s: %s (%d)\n", what, dfs_strerror(r), r);
	exit(1);
}

/* The directory cluster of path ("" or "/" = root); *entry gets the last
 * component when last is set. */
static uint32_t resolve(DFSVOLUME *v, const char *path, int last, DFSENTRY *entry, char *leaf)
{
	char buf[1024];
	snprintf(buf, sizeof(buf), "%s", path);
	uint32_t dir = 0;
	char *save = NULL;
	char *parts[64];
	int n = 0;
	for (char *p = strtok_r(buf, "/", &save); p && n < 64; p = strtok_r(NULL, "/", &save)) {
		parts[n++] = p;
	}
	int walk = last ? n - 1 : n;
	for (int i = 0; i < walk; i++) {
		uint8_t name[11];
		dfs_shortname(parts[i], name);
		DFSENTRY e;
		int r = dfs_find(v, dir, name, &e);
		if (r != DFS_OK) {
			fail(r, parts[i]);
		}
		if (!(e.attr & DFS_ATTR_DIRECTORY)) {
			fail(DFS_ENOTDIR, parts[i]);
		}
		dir = e.cluster;
	}
	if (last) {
		if (n == 0) {
			fail(DFS_EINVAL, path);
		}
		snprintf(leaf, 256, "%s", parts[n - 1]);
		if (entry) {
			uint8_t name[11];
			dfs_shortname(parts[n - 1], name);
			int r = dfs_find(v, dir, name, entry);
			if (r != DFS_OK) {
				fail(r, parts[n - 1]);
			}
		}
	}
	return dir;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: dfstool <image> info|ls|cat|put|mkdir|rm|mv ...\n");
		return 2;
	}
	const char *cmd = argv[2];
	int readonly = !strcmp(cmd, "info") || !strcmp(cmd, "ls") || !strcmp(cmd, "cat");
	int err;
	DFSIMAGE *img = dfs_open(argv[1], !readonly, &err);
	if (img == NULL) {
		fail(err, argv[1]);
	}
	if (!strcmp(cmd, "info")) {
		for (int i = 0; i < dfs_volumecount(img); i++) {
			DFSVOLUMEINFO info;
			dfs_volumeinfo(dfs_volume(img, i), &info);
			printf("%d: FAT%d name=\"%s\" label=\"%s\" total=%llu free=%llu\n", i, info.fattype,
			       info.name, info.label, (unsigned long long)info.totalbytes, (unsigned long long)info.freebytes);
		}
		dfs_close(img);
		return 0;
	}
	if (argc < 4) {
		fprintf(stderr, "volume?\n");
		return 2;
	}
	DFSVOLUME *v = dfs_volume(img, atoi(argv[3]));
	if (v == NULL) {
		fail(DFS_EINVAL, "volume");
	}
	char leaf[256];
	uint16_t date, time;
	dfs_dostime(1760000000, &date, &time);
	int r = DFS_OK;
	if (!strcmp(cmd, "ls")) {
		uint32_t dir = resolve(v, argc > 4 ? argv[4] : "", 0, NULL, NULL);
		DFSENTRY *entries;
		int count;
		r = dfs_listdir(v, dir, &entries, &count);
		if (r != DFS_OK) {
			fail(r, "ls");
		}
		for (int i = 0; i < count; i++) {
			DFSENTRY *e = &entries[i];
			printf("%-12s %s %10u %04d-%02d-%02d %02d:%02d\n", e->display,
			       (e->attr & DFS_ATTR_DIRECTORY) ? "<DIR>" : "     ", e->size,
			       (e->date >> 9) + 1980, (e->date >> 5) & 15, e->date & 31, e->time >> 11, (e->time >> 5) & 63);
		}
		free(entries);
	}
	else if (!strcmp(cmd, "cat") && argc > 4) {
		DFSENTRY e;
		resolve(v, argv[4], 1, &e, leaf);
		uint8_t *data;
		uint32_t size;
		r = dfs_readfile(v, &e, &data, &size);
		if (r == DFS_OK) {
			fwrite(data, 1, size, stdout);
			free(data);
		}
	}
	else if (!strcmp(cmd, "put") && argc > 5) {
		uint32_t dir = resolve(v, argv[4], 0, NULL, NULL);
		FILE *f = fopen(argv[5], "rb");
		if (f == NULL) {
			perror(argv[5]);
			return 1;
		}
		fseek(f, 0, SEEK_END);
		long size = ftell(f);
		fseek(f, 0, SEEK_SET);
		uint8_t *data = malloc(size ? (size_t)size : 1);
		fread(data, 1, (size_t)size, f);
		fclose(f);
		const char *name = argc > 6 ? argv[6] : strrchr(argv[5], '/') ? strrchr(argv[5], '/') + 1 : argv[5];
		uint8_t n83[11];
		r = dfs_uniquename(v, dir, name, n83);
		if (r >= 0) {
			char shown[13];
			dfs_displayname(n83, shown);
			printf("%s\n", shown);
			r = dfs_writefile(v, dir, n83, data, (uint32_t)size, date, time);
		}
		free(data);
	}
	else if (!strcmp(cmd, "mkdir") && argc > 4) {
		uint32_t dir = resolve(v, argv[4], 1, NULL, leaf);
		uint8_t n83[11];
		r = dfs_shortname(leaf, n83);
		if (r >= 0) {
			r = dfs_mkdir(v, dir, n83, date, time, NULL);
		}
	}
	else if (!strcmp(cmd, "rm") && argc > 4) {
		DFSENTRY e;
		uint32_t dir = resolve(v, argv[4], 1, &e, leaf);
		r = dfs_remove(v, dir, e.name);
	}
	else if (!strcmp(cmd, "mv") && argc > 5) {
		DFSENTRY e;
		uint32_t dir = resolve(v, argv[4], 1, &e, leaf);
		uint8_t n83[11];
		r = dfs_shortname(argv[5], n83);
		if (r >= 0) {
			r = dfs_rename(v, dir, e.name, n83);
		}
	}
	else {
		fprintf(stderr, "bad command\n");
		return 2;
	}
	dfs_close(img);
	if (r < 0) {
		fail(r, cmd);
	}
	return 0;
}
