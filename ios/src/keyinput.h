/**
 * @file	keyinput.h
 * @brief	Keyboard input: layout conversion and on-screen PC-98 keys
 */

#pragma once

#include "compiler.h"

#ifdef __cplusplus
extern "C" {
#endif

/* PC-98 key codes used by the on-screen keys */
enum {
	PC98KEY_ESC		= 0x00,
	PC98KEY_BS		= 0x0e,
	PC98KEY_TAB		= 0x0f,
	PC98KEY_RETURN	= 0x1c,
	PC98KEY_SPACE	= 0x34,
	PC98KEY_XFER	= 0x35,
	PC98KEY_ROLLUP	= 0x36,
	PC98KEY_ROLLDOWN = 0x37,
	PC98KEY_INS		= 0x38,
	PC98KEY_DEL		= 0x39,
	PC98KEY_UP		= 0x3a,
	PC98KEY_LEFT	= 0x3b,
	PC98KEY_RIGHT	= 0x3c,
	PC98KEY_DOWN	= 0x3d,
	PC98KEY_HOMECLR	= 0x3e,
	PC98KEY_HELP	= 0x3f,
	PC98KEY_NFER	= 0x51,
	PC98KEY_VF1		= 0x52,	/* vf.1 - vf.5: 0x52 - 0x56 */
	PC98KEY_STOP	= 0x60,
	PC98KEY_COPY	= 0x61,
	PC98KEY_F1		= 0x62,	/* f.1 - f.10: 0x62 - 0x6b */
	PC98KEY_SHIFT	= 0x70,
	PC98KEY_CAPS	= 0x71,
	PC98KEY_KANA	= 0x72,
	PC98KEY_GRPH	= 0x73,
	PC98KEY_CTRL	= 0x74
};

enum {
	KEYLAYOUT_JIS	= 0,	/* hardware keys map by position (PC-98 is JIS-like) */
	KEYLAYOUT_US	= 1		/* symbols are converted to the PC-98 key that prints them */
};

/* Takes over keyboard events from SDL. SDL clears the filter until its
 * event loop runs, so this is called once the window exists (keybar.m). */
void keyinput_initialize(void);

void keyinput_setlayout(int layout);

/* Whether the software keyboard is on screen (its keys arrive as US positions). */
void keyinput_setsoftkeyboard(BOOL shown);

/* On-screen keys (main thread). Ordinary keys release any latched modifier
 * when they go up. */
void keyinput_down(UINT8 key);
void keyinput_up(UINT8 key);

/* SHIFT / CTRL / GRPH latch until the next key; CAPS / KANA toggle. */
void keyinput_togglemodifier(UINT8 key);
BOOL keyinput_isactive(UINT8 key);

/* SHIFT / CTRL / GRPH held down by a finger on the on-screen keyboard. When
 * nothing else was pressed meanwhile (a tap), release with latch = TRUE: the
 * modifier then stays down for the next key, as keyinput_togglemodifier(). */
void keyinput_holdmodifier(UINT8 key);
void keyinput_releasemodifier(UINT8 key, BOOL latch);

/* Called when the state shown by keyinput_isactive() may have changed. */
extern void (*keyinput_onchange)(void);

#ifdef __cplusplus
}
#endif
