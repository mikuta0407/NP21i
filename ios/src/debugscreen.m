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
#include "textscreen.h"

#ifndef NDEBUG

#import <Foundation/Foundation.h>
#include <cpucore.h>
#include <pccore.h>
#include <io/iocore.h>
#include <cbus/mpu98ii.h>

static void dump_screen(FILE *fp)
{
	UINT csrw = LOADINTELWORD(gdc.m.para + GDC_CSRW);
	fprintf(fp, "cursor: row %u col %u (%s)\n", csrw / TEXTSCREEN_COLS, csrw % TEXTSCREEN_COLS,
		(gdc.m.para[GDC_CSRFORM] & 0x80) ? "shown" : "hidden");
	fprintf(fp, "pit0: value %u ctrl %02x | mpu: mode %u flag1 %02x flag2 %02x\n",
		pit.ch[0].value, pit.ch[0].ctrl, mpu98.mode, mpu98.flag1, mpu98.flag2);
	for (int row = 0; row < TEXTSCREEN_ROWS; row++) {
		char marks[TEXTSCREEN_COLS * 2 + 1];
		NSString *line = textscreen_row(row, YES, marks);
		fprintf(fp, "%2d|%s\n", row, line.UTF8String);
		if (strspn(marks, " ") != strlen(marks)) {
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
