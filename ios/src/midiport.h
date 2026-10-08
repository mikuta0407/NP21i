/**
 * @file	midiport.h
 * @brief	CoreMIDI endpoints used by the MIDI COMMNG (cmmidi.c)
 *
 * Endpoint selection strings (np21kai.cfg: mpu98map / mpu98min etc.):
 *   "" or "*"   all hardware/network endpoints
 *   "N/C"       no hardware/network endpoint (the virtual ones below still work)
 *   otherwise   endpoints whose display name contains the string (case-insensitive)
 *
 * The selection string is kept by pointer (it lives in the config) and is
 * looked up again by midiport_refresh() and whenever devices are added or
 * removed, so a Bluetooth device connected later is picked up.
 *
 * Independently of the selection, an opened output is always also sent to the
 * app's virtual source "NP21 MIDI OUT", and an opened input always also receives
 * from the app's virtual destination "NP21 MIDI IN", so other apps can connect.
 * S-MPU's port B has its own pair, "NP21 MIDI OUT B" / "NP21 MIDI IN B"
 * (`virtual` 1). Each open input gets everything its sources send, so two
 * inputs can take from the same device.
 */

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#define MIDIPORT_ALL		"*"
#define MIDIPORT_NC			"N/C"

enum {
	MIDIPORT_VIRTUALS	= 2		/* virtual endpoint pairs: the main port and S-MPU's B */
};

typedef struct _midiport_out *MIDIPORTOUT;
typedef struct _midiport_in *MIDIPORTIN;

/* Creates the CoreMIDI client and the virtual endpoints. Safe to call more than once. */
BOOL midiport_initialize(void);

/* Re-resolves the selections of all open handles (main thread). */
void midiport_refresh(void);
/* Names of the hardware/network endpoints (not the app's virtual ones). */
void midiport_list(BOOL sources, void (^callback)(const char *name));
/* Called on the main thread after the MIDI setup changed. */
extern void (*midiport_onchange)(void);

/* Returns NULL only when CoreMIDI is unavailable. `selection` must stay valid
 * until the handle is closed. `virtual`: which of the app's virtual endpoint
 * pairs also gets the data (0 "NP21 MIDI OUT/IN", 1 "... B"). */
MIDIPORTOUT midiport_openout(const char *selection, UINT virtual);
/* timestamp: mach_absolute_time() based host time to deliver at, 0 = now. */
void midiport_send(MIDIPORTOUT hdl, const UINT8 *data, UINT length, UINT64 timestamp);
void midiport_closeout(MIDIPORTOUT hdl);

MIDIPORTIN midiport_openin(const char *selection, UINT virtual);
/* Non-blocking. Returns 1 and stores a byte when a byte that arrived at or
 * before host time `until` (mach_absolute_time based, 0 = any) is available. */
UINT midiport_read(MIDIPORTIN hdl, UINT8 *data, UINT64 until);
/* Arrival time of the byte returned by the last successful midiport_read. */
UINT64 midiport_lastreadtime(MIDIPORTIN hdl);
void midiport_closein(MIDIPORTIN hdl);

/* Testing: logs each open input and the bytes waiting in it. */
void midiport_debugdump(void);

#ifdef __cplusplus
}
#endif
