/**
 * @file	keybar.h
 * @brief	On-screen bar with PC-98 keys and the app menu
 */

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Adds the bar to the SDL window once it exists; call before np2_main(). */
void keybar_initialize(void);

/* Testing: taps the bar button with the given label ("f·1", "GRPH", ...),
 * or runs a menu command: "!reset", "!np2menu", "!eject1", "!eject2",
 * "!insert1:<path>", "!insert2:<path>", "!hide", "!show", "!softkbd",
 * "!softtype:<text>" (as if typed on the software keyboard),
 * "!hdd<drv>:<path>" / "!hdd<drv>" (set / remove a hard disk; drv in hex,
 * 00-01 IDE, 20-23 SCSI; takes effect at "!reset"),
 * "!importhdd<drv>:<absolute path>" (copy into hdd/ as if picked elsewhere),
 * "!dumphddmenu" (log the hard disk menu). */
void keybar_debugcommand(const char *command);

#ifdef __cplusplus
}
#endif
