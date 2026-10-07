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

/* Ratio of emulated time to real time over the last second (1.0 = full
 * speed), or a negative value while unknown. Call regularly. */
double lifecycle_emulationspeed(void);

#ifdef __cplusplus
}
#endif
