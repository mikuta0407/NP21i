/**
 * @file	textscreen.m
 * @brief	The PC-98 text screen (text VRAM) as Unicode text
 */

#include "compiler.h"
#include "textscreen.h"

#include <cpucore.h>
#include <pccore.h>

enum {
	TEXT_CODE	= 0xa0000,
	TEXT_ATTR	= 0xa2000
};

/* PC-98 graphic characters (ANK 0x80-0x9f, 0xe0-0xff) */
static const unichar s_graphics80[0x20] = {
	0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588,	/* ▁▂▃▄▅▆▇█ */
	0x258f, 0x258e, 0x258d, 0x258c, 0x258b, 0x258a, 0x2589, 0x253c,	/* ▏▎▍▌▋▊▉┼ */
	0x2534, 0x252c, 0x2524, 0x251c, 0x2594, 0x2500, 0x2502, 0x2595,	/* ┴┬┤├▔─│▕ */
	0x250c, 0x2510, 0x2514, 0x2518, 0x256d, 0x256e, 0x2570, 0x256f,	/* ┌┐└┘╭╮╰╯ */
};
static const unichar s_graphicse0[0x20] = {
	0x2550, 0x255e, 0x256a, 0x2561, 0x25e2, 0x25e3, 0x25e5, 0x25e4,	/* ═╞╪╡◢◣◥◤ */
	0x2660, 0x2665, 0x2666, 0x2663, 0x2022, 0x25cb, 0x2571, 0x2572,	/* ♠♥♦♣•○╱╲ */
	0x2573, 0x5186, 0x5e74, 0x6708, 0x65e5, 0x6642, 0x5206, 0x79d2,	/* ╳円年月日時分秒 */
	' ', ' ', ' ', ' ', 0x005c, ' ', ' ', ' ',
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

/* NEC's Shift_JIS (CP932): also the NEC special characters (row 13: ①, ㍉ ...) */
static NSString *decode_sjis(const char *bytes, NSUInteger length)
{
	static NSStringEncoding cp932;
	if (cp932 == 0) {
		cp932 = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSJapanese);
	}
	NSString *str = [[NSString alloc] initWithBytes:bytes length:length encoding:cp932];
	return str ?: (length == 2 ? @"??" : @"?");
}

static NSString *ank(UINT8 c, BOOL asterisks)
{
	if ((c >= 0x20 && c < 0x7f) || (c >= 0xa1 && c <= 0xdf)) {
		char ch = (char)c;
		return decode_sjis(&ch, 1);
	}
	if (c < 0x20 || c == 0x7f || c == 0xa0) {
		return @" ";
	}
	if (asterisks) {
		return @"*";
	}
	unichar u = (c < 0xa0) ? s_graphics80[c - 0x80] : s_graphicse0[c - 0xe0];
	return [NSString stringWithCharacters:&u length:1];
}

NSString *textscreen_row(int row, BOOL asterisks, char *marks)
{
	NSMutableString *line = [NSMutableString string];
	int nmarks = 0;

	for (int col = 0; col < TEXTSCREEN_COLS; col++) {
		UINT32 off = (UINT32)(row * TEXTSCREEN_COLS + col) * 2;
		UINT8 lo = mem[TEXT_CODE + off];
		UINT8 hi = mem[TEXT_CODE + off + 1];
		char mark = attr_mark(mem[TEXT_ATTR + off]);

		if (hi == 0) {
			[line appendString:(mark == '-' && !marks) ? @" " : ank(lo, asterisks)];
			if (marks) {
				marks[nmarks++] = mark;
			}
		}
		else if (lo & 0x80) {
			/* right half of a double-width character: already emitted */
		}
		else {
			char kanji[2];
			jis2sjis((UINT8)(lo + 0x20), hi, kanji);
			[line appendString:(mark == '-' && !marks) ? @"  " : decode_sjis(kanji, 2)];
			if (marks) {
				marks[nmarks++] = mark;
				marks[nmarks++] = mark;
			}
		}
	}
	if (marks) {
		marks[nmarks] = '\0';
	}
	return line;
}

NSString *textscreen_text(void)
{
	NSMutableArray<NSString *> *rows = [NSMutableArray array];
	NSCharacterSet *blanks = [NSCharacterSet whitespaceCharacterSet];
	for (int row = 0; row < TEXTSCREEN_ROWS; row++) {
		NSString *line = textscreen_row(row, NO, NULL);
		NSRange end = [line rangeOfCharacterFromSet:blanks.invertedSet options:NSBackwardsSearch];
		[rows addObject:(end.location == NSNotFound) ? @"" : [line substringToIndex:NSMaxRange(end)]];
	}
	while (rows.count && rows.lastObject.length == 0) {
		[rows removeLastObject];
	}
	return [rows componentsJoinedByString:@"\n"];
}
