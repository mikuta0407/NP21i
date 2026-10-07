/**
 * @file	debugscreen.m
 * @brief	Text screen dump for testing on the simulator (debug builds only)
 *
 * Creating debugscreen.req in the data directory makes the app write the
 * PC-98 text VRAM to screen.txt (UTF-8) and delete the request. Each text row
 * is followed by an attribute row when any cell in it is highlighted:
 *   R = reverse, B = blink, U = underline, - = hidden (secret)
 * The first line gives the GDC text cursor position (row/col, 0-based).
 * Screenshots are unreliable for this because cursors blink.
 */

#include "compiler.h"
#include "debugscreen.h"

#ifndef NDEBUG

#import <Foundation/Foundation.h>
#include <cpucore.h>
#include <pccore.h>
#include <io/iocore.h>
#include <cbus/mpu98ii.h>

enum {
	TEXT_COLS	= 80,
	TEXT_ROWS	= 25,
	TEXT_CODE	= 0xa0000,
	TEXT_ATTR	= 0xa2000
};

/* JIS X 0208 row/cell -> Shift_JIS bytes */
static void jis2sjis(UINT8 j1, UINT8 j2, char *out)
{
	UINT8 s1 = (UINT8)(((j1 + 1) >> 1) + ((j1 <= 0x5e) ? 0x70 : 0xb0));
	UINT8 s2 = (UINT8)((j1 & 1) ? (j2 + ((j2 >= 0x60) ? 0x20 : 0x1f)) : (j2 + 0x7e));
	out[0] = (char)s1;
	out[1] = (char)s2;
}

static char attr_mark(UINT8 attr)
{
	if (!(attr & 0x01)) {
		return '-';
	}
	if (attr & 0x04) {
		return 'R';
	}
	if (attr & 0x02) {
		return 'B';
	}
	if (attr & 0x08) {
		return 'U';
	}
	return ' ';
}

static NSString *decode_sjis(const char *bytes, NSUInteger length)
{
	NSString *str = [[NSString alloc] initWithBytes:bytes length:length encoding:NSShiftJISStringEncoding];
	return str ?: (length == 2 ? @"??" : @"?");
}

static void dump_screen(FILE *fp)
{
	UINT csrw = LOADINTELWORD(gdc.m.para + GDC_CSRW);
	fprintf(fp, "cursor: row %u col %u (%s)\n", csrw / TEXT_COLS, csrw % TEXT_COLS,
		(gdc.m.para[GDC_CSRFORM] & 0x80) ? "shown" : "hidden");
	fprintf(fp, "pit0: value %u ctrl %02x | mpu: mode %u flag1 %02x flag2 %02x\n",
		pit.ch[0].value, pit.ch[0].ctrl, mpu98.mode, mpu98.flag1, mpu98.flag2);
	for (int row = 0; row < TEXT_ROWS; row++) {
		NSMutableString *line = [NSMutableString string];
		char marks[TEXT_COLS * 2 + 1];
		int nmarks = 0;
		BOOL highlighted = NO;

		for (int col = 0; col < TEXT_COLS; col++) {
			UINT32 off = (UINT32)(row * TEXT_COLS + col) * 2;
			UINT8 lo = mem[TEXT_CODE + off];
			UINT8 hi = mem[TEXT_CODE + off + 1];
			char mark = attr_mark(mem[TEXT_ATTR + off]);
			highlighted |= (mark != ' ');

			if (hi == 0) {
				/* ANK; PC-98 graphic characters (0x80-0x9f, 0xe0-0xff) shown as '*' */
				char c = ((lo >= 0x20 && lo < 0x7f) || (lo >= 0xa1 && lo <= 0xdf)) ? (char)lo
					: (lo < 0x20 ? ' ' : '*');
				[line appendString:decode_sjis(&c, 1)];
				marks[nmarks++] = mark;
			}
			else if (lo & 0x80) {
				/* right half of a double-width character: already emitted */
			}
			else {
				char kanji[2];
				jis2sjis((UINT8)(lo + 0x20), hi, kanji);
				[line appendString:decode_sjis(kanji, 2)];
				marks[nmarks++] = mark;
				marks[nmarks++] = mark;
			}
		}
		marks[nmarks] = '\0';

		fprintf(fp, "%2d|%s\n", row, line.UTF8String);
		if (highlighted) {
			fprintf(fp, "  |%s\n", marks);
		}
	}
}

void debugscreen_poll(void)
{
	/* cwd is the data directory (see main.m) */
	if (access("debugscreen.req", F_OK) != 0) {
		return;
	}
	remove("debugscreen.req");
	FILE *fp = fopen("screen.txt.tmp", "w");
	if (fp == NULL) {
		return;
	}
	@autoreleasepool {
		dump_screen(fp);
	}
	fclose(fp);
	rename("screen.txt.tmp", "screen.txt");
}

#else

void debugscreen_poll(void)
{
}

#endif
