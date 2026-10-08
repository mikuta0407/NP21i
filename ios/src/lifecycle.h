/**
 * @file	lifecycle.h
 * @brief	Background / foreground handling and resuming the last session
 */

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Call once the emulator has started (keybar.m does): restores the state
 * saved when the app last went to the background, and starts watching. */
void lifecycle_start(void);

/* Saves the machine to np2.sav now (deletes it with resuming turned off);
 * loads it, as at start, returning nonzero when it was (profile.m). */
void lifecycle_savestate(void);
int lifecycle_restorestate(void);

/* Ratio of emulated time to real time over the last second (1.0 = full
 * speed), or a negative value while unknown. Call regularly. */
double lifecycle_emulationspeed(void);

/* The emulator stops (sound and MIDI too) while the app's own screens are
 * shown; calls nest. NP2PausingNavigationController does this. */
void lifecycle_pause(void);
void lifecycle_resume(void);

/* For sdl/np2.c's main loop (NP2kai patch 0007): when paused, runs the UI
 * for a frame's time and returns nonzero. */
int np2ios_pausewait(void);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <UIKit/UIKit.h>

/* For the app's own screens (settings, disk files): the emulator is paused
 * from when it appears until it is dismissed. */
@interface NP2PausingNavigationController : UINavigationController
@end
#endif
