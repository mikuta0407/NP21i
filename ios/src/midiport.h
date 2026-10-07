/**
 * @file	midiport.h
 * @brief	CoreMIDI endpoints used by the MIDI COMMNG (cmmidi.c)
 *
 * Endpoint selection strings (np21kai.cfg: mpu98map / mpu98min etc.):
 *   "" or "*"   all hardware/network endpoints
 *   "N/C"       not connected
 *   otherwise   endpoints whose display name contains the string (case-insensitive)
 *
 * Independently of the selection, an opened output is always also sent to the
 * app's virtual source "NP21 MIDI OUT", and an opened input always also receives
 * from the app's virtual destination "NP21 MIDI IN", so other apps can connect.
 */

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#define MIDIPORT_ALL		"*"
#define MIDIPORT_NC			"N/C"

typedef struct _midiport_out *MIDIPORTOUT;
typedef struct _midiport_in *MIDIPORTIN;

/* Creates the CoreMIDI client and the virtual endpoints. Safe to call more than once. */
BOOL midiport_initialize(void);

/* Returns NULL when the selection is "N/C" or CoreMIDI is unavailable. */
MIDIPORTOUT midiport_openout(const char *selection);
/* timestamp: mach_absolute_time() based host time to deliver at, 0 = now. */
void midiport_send(MIDIPORTOUT hdl, const UINT8 *data, UINT length, UINT64 timestamp);
void midiport_closeout(MIDIPORTOUT hdl);

MIDIPORTIN midiport_openin(const char *selection);
/* Non-blocking. Returns 1 and stores a byte when a byte that arrived at or
 * before host time `until` (mach_absolute_time based, 0 = any) is available. */
UINT midiport_read(MIDIPORTIN hdl, UINT8 *data, UINT64 until);
/* Arrival time of the byte returned by the last successful midiport_read. */
UINT64 midiport_lastreadtime(MIDIPORTIN hdl);
void midiport_closein(MIDIPORTIN hdl);

#ifdef __cplusplus
}
#endif
