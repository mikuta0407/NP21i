/**
 * @file	keyinput.m
 * @brief	Keyboard input: layout conversion and on-screen PC-98 keys
 *
 * All SDL key events are handled here (by an event filter) instead of in
 * sdl/taskmng.c, so that they can be mixed in order with the on-screen keys:
 *
 * - sdl/kbtrans.c maps keys by position, which matches JIS keyboards (the
 *   PC-98 keyboard is JIS-like). With KEYLAYOUT_US, and always for the
 *   software keyboard (SDL turns its characters into US key positions),
 *   symbol keys are converted to the PC-98 key that prints the same
 *   character, pressing or releasing SHIFT around it as needed.
 * - SHIFT / CTRL / GRPH tapped on the on-screen keys latch until the next
 *   key goes up.
 *
 * GCKeyboard delivers key events on a background queue; they are moved to
 * the main thread, where the emulator runs.
 */

#include "compiler.h"
#include "keyinput.h"

#import <Foundation/Foundation.h>
#include <SDL2/SDL.h>
#include <keystat.h>
#include <kbtrans.h>

void (*keyinput_onchange)(void);

typedef struct {
	UINT8	normal;		/* PC-98 key (bit 7 = with SHIFT) for the unshifted US key */
	UINT8	shifted;	/* ... for the shifted US key */
} USKEY;

#define S	0x80

/* US symbol keys -> PC-98 keys printing the same character */
static const struct {
	SDL_Scancode	scancode;
	USKEY			key;
} s_ustable[] = {
	{SDL_SCANCODE_2,			{0x02,		0x1a}},		/* 2 @ */
	{SDL_SCANCODE_6,			{0x06,		0x0c}},		/* 6 ^ */
	{SDL_SCANCODE_7,			{0x07,		0x06 | S}},	/* 7 & */
	{SDL_SCANCODE_8,			{0x08,		0x27 | S}},	/* 8 * */
	{SDL_SCANCODE_9,			{0x09,		0x08 | S}},	/* 9 ( */
	{SDL_SCANCODE_0,			{0x0a,		0x09 | S}},	/* 0 ) */
	{SDL_SCANCODE_MINUS,		{0x0b,		0x33 | S}},	/* - _ */
	{SDL_SCANCODE_EQUALS,		{0x0b | S,	0x26 | S}},	/* = + */
	{SDL_SCANCODE_LEFTBRACKET,	{0x1b,		0x1b | S}},	/* [ { */
	{SDL_SCANCODE_RIGHTBRACKET,	{0x28,		0x28 | S}},	/* ] } */
	{SDL_SCANCODE_BACKSLASH,	{0x0d,		0x0d | S}},	/* \ | (Yen key) */
	{SDL_SCANCODE_SEMICOLON,	{0x26,		0x27}},		/* ; : */
	{SDL_SCANCODE_APOSTROPHE,	{0x07 | S,	0x02 | S}},	/* ' " */
	{SDL_SCANCODE_GRAVE,		{0x0c | S,	0x1a | S}},	/* ` ~ */
};

#undef S

static int s_layout = KEYLAYOUT_JIS;
static BOOL s_softkeyboard;
static BOOL s_shiftheld[2];					/* physical left / right SHIFT */
static UINT8 s_converted[SDL_NUM_SCANCODES];	/* PC-98 key sent for a converted key, 0 = none */
static int s_shiftadjust[SDL_NUM_SCANCODES];	/* +1 SHIFT pressed / -1 released for it */
static BOOL s_latched[0x80];				/* on-screen modifiers */

static void changed(void)
{
	if (keyinput_onchange) {
		keyinput_onchange();
	}
}

static BOOL shift_down(void)
{
	return s_shiftheld[0] || s_shiftheld[1] || s_latched[PC98KEY_SHIFT];
}

static void release_latched(void)
{
	BOOL any = FALSE;
	for (UINT i = 0; i < NELEMENTS(s_latched); i++) {
		if (s_latched[i]) {
			s_latched[i] = FALSE;
			keystat_keyup((REG8)i);
			any = TRUE;
		}
	}
	if (any) {
		changed();
	}
}

static const USKEY *us_key(SDL_Scancode sc)
{
	for (UINT i = 0; i < NELEMENTS(s_ustable); i++) {
		if (s_ustable[i].scancode == sc) {
			return &s_ustable[i].key;
		}
	}
	return NULL;
}

static BOOL convert_us(void)
{
	if (s_layout == KEYLAYOUT_US) {
		return TRUE;
	}
	/* The software keyboard: SDL sends US key positions for its characters.
	 * (SDL_IsTextInputActive() is no help: SDL enables text input at start,
	 * and GCKeyboard can report a keyboard while the software one is used,
	 * e.g. the Mac's in the simulator.) */
	return s_softkeyboard;
}

static void converted_down(SDL_Scancode sc, UINT8 key)
{
	BOOL wantshift = (key & 0x80) != 0;
	key &= 0x7f;
	int adjust = 0;
	if (wantshift && !shift_down()) {
		keystat_keydown(PC98KEY_SHIFT);
		adjust = 1;
	}
	else if (!wantshift && shift_down()) {
		keystat_keyup(PC98KEY_SHIFT);
		adjust = -1;
	}
	keystat_keydown(key);
	s_converted[sc] = key | 0x80;	/* 0x80: so that key 0x00 is not "none" */
	s_shiftadjust[sc] = adjust;
}

static void converted_up(SDL_Scancode sc)
{
	keystat_keyup(s_converted[sc] & 0x7f);
	/* Put SHIFT back as the user is holding it now. */
	if (s_shiftadjust[sc] > 0 && !shift_down()) {
		keystat_keyup(PC98KEY_SHIFT);
	}
	else if (s_shiftadjust[sc] < 0 && shift_down()) {
		keystat_keydown(PC98KEY_SHIFT);
	}
	s_converted[sc] = 0;
	s_shiftadjust[sc] = 0;
}

static void handle_key(SDL_Scancode sc, BOOL down)
{
	if (sc == SDL_SCANCODE_LSHIFT || sc == SDL_SCANCODE_RSHIFT) {
		s_shiftheld[sc == SDL_SCANCODE_RSHIFT] = down;
	}
	if (down) {
		const USKEY *us = convert_us() ? us_key(sc) : NULL;
		if (s_converted[sc]) {
			/* auto-repeat: the PC-98 side repeats by itself */
		}
		else if (us) {
			converted_down(sc, shift_down() ? us->shifted : us->normal);
		}
		else {
			sdlkbd_keydown(sc);
		}
	}
	else {
		if (s_converted[sc]) {
			converted_up(sc);
		}
		else {
			sdlkbd_keyup(sc);
		}
		if (sc != SDL_SCANCODE_LSHIFT && sc != SDL_SCANCODE_RSHIFT) {
			release_latched();
		}
	}
}

/* sdl/taskmng.c keeps these: F11 opens the menu, Cmd+F toggles fullscreen. */
static BOOL taskmng_handles(const SDL_KeyboardEvent *key)
{
	return key->keysym.scancode == SDL_SCANCODE_F11 || (key->keysym.mod & KMOD_GUI);
}

static int SDLCALL event_filter(void *userdata, SDL_Event *event)
{
	(void)userdata;
	if (event->type != SDL_KEYDOWN && event->type != SDL_KEYUP) {
		return 1;
	}
	if (taskmng_handles(&event->key)) {
		return 1;
	}
	SDL_Scancode sc = event->key.keysym.scancode;
	BOOL down = (event->type == SDL_KEYDOWN);
	if ((UINT)sc >= SDL_NUM_SCANCODES) {
		return 0;
	}
	if ([NSThread isMainThread]) {
		handle_key(sc, down);
	}
	else {
		dispatch_async(dispatch_get_main_queue(), ^{
			handle_key(sc, down);
		});
	}
	return 0;
}

void keyinput_initialize(void)
{
	SDL_SetEventFilter(event_filter, NULL);
}

void keyinput_setlayout(int layout)
{
	s_layout = layout;
}

void keyinput_setsoftkeyboard(BOOL shown)
{
	s_softkeyboard = shown;
}

void keyinput_down(UINT8 key)
{
	keystat_keydown(key);
}

void keyinput_up(UINT8 key)
{
	keystat_keyup(key);
	release_latched();
}

void keyinput_togglemodifier(UINT8 key)
{
	if (key == PC98KEY_CAPS || key == PC98KEY_KANA) {
		/* lock keys: each press toggles */
		keystat_keydown(key);
		keystat_keyup(key);
	}
	else if (s_latched[key]) {
		s_latched[key] = FALSE;
		keystat_keyup(key);
	}
	else {
		s_latched[key] = TRUE;
		keystat_keydown(key);
	}
	changed();
}

BOOL keyinput_isactive(UINT8 key)
{
	if (key == PC98KEY_CAPS || key == PC98KEY_KANA) {
		return keystat.ref[key] != NKEYREF_NC;
	}
	return s_latched[key & 0x7f];
}
