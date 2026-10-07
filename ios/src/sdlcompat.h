/**
 * @file	sdlcompat.h
 * @brief	The few SDL calls of the iOS layer, for SDL2 and SDL3 (USE_SDL)
 */

#pragma once

#if USE_SDL >= 3
#include <SDL3/SDL.h>

#define NP21_EVENT_KEYDOWN		SDL_EVENT_KEY_DOWN
#define NP21_EVENT_KEYUP		SDL_EVENT_KEY_UP
#define NP21_NUM_SCANCODES		SDL_SCANCODE_COUNT
#define NP21_KMOD_GUI			SDL_KMOD_GUI
#define NP21_KEY_SCANCODE(k)	((k)->scancode)
#define NP21_KEY_MOD(k)			((k)->mod)
typedef bool NP21_FILTERRESULT;

#else
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#define NP21_EVENT_KEYDOWN		SDL_KEYDOWN
#define NP21_EVENT_KEYUP		SDL_KEYUP
#define NP21_NUM_SCANCODES		SDL_NUM_SCANCODES
#define NP21_KMOD_GUI			KMOD_GUI
#define NP21_KEY_SCANCODE(k)	((k)->keysym.scancode)
#define NP21_KEY_MOD(k)			((k)->keysym.mod)
typedef int NP21_FILTERRESULT;
#endif

#ifdef __OBJC__
#import <UIKit/UIKit.h>

/* The UIWindow of the first SDL window, or nil before it exists. */
static inline UIWindow *np21_sdl_uiwindow(void)
{
#if USE_SDL >= 3
	int count = 0;
	SDL_Window **windows = SDL_GetWindows(&count);
	UIWindow *uiwindow = nil;
	if (windows && count > 0) {
		uiwindow = (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(windows[0]),
			SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	}
	SDL_free(windows);
	return uiwindow;
#else
	for (Uint32 id = 1; id < 8; id++) {
		SDL_Window *window = SDL_GetWindowFromID(id);
		if (window == NULL) {
			continue;
		}
		SDL_SysWMinfo info;
		SDL_VERSION(&info.version);
		if (SDL_GetWindowWMInfo(window, &info) && info.subsystem == SDL_SYSWM_UIKIT) {
			return info.info.uikit.window;
		}
	}
	return nil;
#endif
}
#endif

/* Software keyboard (text input) of the first SDL window. */
static inline void np21_starttextinput(void)
{
#if USE_SDL >= 3
	int count = 0;
	SDL_Window **windows = SDL_GetWindows(&count);
	if (windows && count > 0) {
		SDL_StartTextInput(windows[0]);
	}
	SDL_free(windows);
#else
	SDL_StartTextInput();
#endif
}

static inline void np21_stoptextinput(void)
{
#if USE_SDL >= 3
	int count = 0;
	SDL_Window **windows = SDL_GetWindows(&count);
	if (windows && count > 0) {
		SDL_StopTextInput(windows[0]);
	}
	SDL_free(windows);
#else
	SDL_StopTextInput();
#endif
}

/* Pushes a key event as if from a keyboard (testing). */
static inline void np21_pushkey(SDL_Scancode sc, int down)
{
	SDL_Event e;
	SDL_zero(e);
#if USE_SDL >= 3
	e.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
	e.key.down = down ? true : false;
	e.key.scancode = sc;
	e.key.key = SDL_GetKeyFromScancode(sc, SDL_KMOD_NONE, false);
#else
	e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
	e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
	e.key.keysym.scancode = sc;
	e.key.keysym.sym = SDL_GetKeyFromScancode(sc);
#endif
	SDL_PushEvent(&e);
}
