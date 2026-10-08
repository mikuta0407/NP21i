/**
 * @file	synth.h
 * @brief	The built-in MIDI sound generator (a SoundFont / DLS bank played by
 *			Apple's MIDISynth), mixed into the PC-98's sound
 *
 * The MPU's output can go here instead of to a MIDI device (cmmidi.c, the
 * output selection CMMIDI_SYNTH). It is rendered as part of the emulator's
 * sound (NP2kai patch 0018), so its notes start exactly when the emulated
 * program sends them, and it is heard, recorded and turned down with the
 * rest. iOS has no General MIDI bank of its own: the user adds a .sf2 or
 * .dls file (e.g. GeneralUser GS) to soundfont/ in the data directory.
 *
 * All calls on the emulator's (main) thread.
 */

#pragma once

#include "compiler.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The output selection string (np21kai.cfg mpu98map...) for the built-in synth. */
extern const char cmmidi_synth[];

/* Users of the synth (MIDI ports set to it); it plays while there is one. */
void synth_open(void);
void synth_close(void);

void synth_shortmsg(const UINT8 *msg, UINT length);
void synth_sysex(const UINT8 *data, UINT length);
void synth_allnotesoff(void);

/* Reloads the bank and the volume after the settings changed. */
void synth_settingschanged(void);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>

extern NSString *const kSettingSynthBank;		/* file name in soundfont/, nil = the first there */
extern NSString *const kSettingSynthVolume;		/* 0-128, 100 standard */

/* soundfont/ (relative to the data directory) and the banks in it. */
NSString *synth_bankdir(void);
NSArray<NSString *> *synth_banks(void);
/* The bank used: the chosen one, or the first; nil when there is none. */
NSString *synth_bank(void);
/* Whether a bank file name is one the synth takes (.sf2, .dls). */
BOOL synth_isbank(NSString *name);
#endif
