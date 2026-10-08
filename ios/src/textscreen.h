/**
 * @file	textscreen.h
 * @brief	The PC-98 text screen (text VRAM) as Unicode text
 */

#pragma once

#import <Foundation/Foundation.h>

enum {
	TEXTSCREEN_COLS	= 80,
	TEXTSCREEN_ROWS	= 25
};

/* One row of the text screen. PC-98 graphic characters (lines, blocks) are
 * drawn with their Unicode look-alikes, or as '*' when `asterisks`. Hidden
 * (secret) cells are blanks. When `marks` is given (TEXTSCREEN_COLS * 2 + 1
 * bytes), it gets a highlight mark per column used:
 *   R = reverse, B = blink, U = underline, - = hidden, ' ' = none */
NSString *textscreen_row(int row, BOOL asterisks, char *marks);

/* The whole text screen, rows without trailing blanks, and no blank rows at
 * the end. */
NSString *textscreen_text(void);
