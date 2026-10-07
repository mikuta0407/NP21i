/**
 * @file	debugkeys.m
 * @brief	Scripted key input for testing on a headless simulator (debug builds only)
 *
 * NP2_DEBUG_KEYS="<delay ms>:<key>[+<key>...],..."
 * Each step waits <delay ms>, then presses the keys in order and releases them
 * in reverse. Key names are SDL scancode names (SDL_GetScancodeFromName),
 * e.g. "3000:F10,500:Down,500:Return,1000:Left Shift+F9", or "#<number>"
 * for scancodes without a name (e.g. "#135" = International 1, PC-98 "_").
 * "@<command>" is passed to keybar_debugcommand() instead (on-screen keys
 * and menu commands, e.g. "500:@f·1", "500:@!reset").
 *
 * Pass it through simctl with the SIMCTL_CHILD_ prefix:
 *   SIMCTL_CHILD_NP2_DEBUG_KEYS="..." xcrun simctl launch <udid> <bundle id>
 *
 * While the app runs, a script written to debugkeys.txt in the data directory
 * is also executed (same format) and the file is deleted.
 */

#include "debugkeys.h"
#include "debugscreen.h"
#include "keybar.h"

#ifndef NDEBUG

#include <SDL2/SDL.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_COMBO 4
#define HOLD_MS 80

static void push_key(SDL_Scancode sc, BOOL down)
{
	SDL_Event e;
	SDL_zero(e);
	e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
	e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
	e.key.keysym.scancode = sc;
	e.key.keysym.sym = SDL_GetKeyFromScancode(sc);
	SDL_PushEvent(&e);
}

static void run_script(char *script)
{
	char *saveptr = NULL;

	for (char *step = strtok_r(script, ",", &saveptr); step; step = strtok_r(NULL, ",", &saveptr)) {
		char *colon = strchr(step, ':');
		if (!colon) {
			fprintf(stderr, "debugkeys: bad step '%s'\n", step);
			continue;
		}
		*colon = '\0';
		usleep((useconds_t)atoi(step) * 1000);
		char label[128];
		SDL_strlcpy(label, colon + 1, sizeof(label));
		if (label[0] == '@') {
			keybar_debugcommand(label + 1);
			fprintf(stderr, "debugkeys: sent %s\n", label);
			continue;
		}

		SDL_Scancode combo[MAX_COMBO];
		int count = 0;
		char *keyptr = NULL;
		for (char *name = strtok_r(colon + 1, "+", &keyptr); name && count < MAX_COMBO; name = strtok_r(NULL, "+", &keyptr)) {
			SDL_Scancode sc = (name[0] == '#') ? (SDL_Scancode)atoi(name + 1) : SDL_GetScancodeFromName(name);
			if (sc == SDL_SCANCODE_UNKNOWN) {
				fprintf(stderr, "debugkeys: unknown key '%s'\n", name);
				continue;
			}
			combo[count++] = sc;
		}
		for (int i = 0; i < count; i++) {
			push_key(combo[i], TRUE);
			usleep(HOLD_MS * 1000);
		}
		for (int i = count - 1; i >= 0; i--) {
			push_key(combo[i], FALSE);
			usleep(HOLD_MS * 1000);
		}
		fprintf(stderr, "debugkeys: sent %s\n", label);
	}
}

static void *debugkeys_thread(void *arg)
{
	char *script = arg;

	if (script) {
		run_script(script);
		free(script);
	}
	/* cwd is the data directory (see main.m) */
	for (;;) {
		usleep(300 * 1000);
		debugscreen_poll();
		FILE *fp = fopen("debugkeys.txt", "r");
		if (!fp) {
			continue;
		}
		char buf[4096];
		size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
		fclose(fp);
		remove("debugkeys.txt");
		buf[n] = '\0';
		buf[strcspn(buf, "\r\n")] = '\0';
		run_script(buf);
	}
	return NULL;
}

void debugkeys_start(void)
{
	const char *script = getenv("NP2_DEBUG_KEYS");
	pthread_t th;
	if (pthread_create(&th, NULL, debugkeys_thread, (script && script[0]) ? strdup(script) : NULL) == 0) {
		pthread_detach(th);
	}
}

#else

void debugkeys_start(void)
{
}

#endif
