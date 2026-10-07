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

/* Lets the user pick a hard disk image for a slot (0x00-0x01 IDE,
 * 0x20-0x23 SCSI, or KEYBAR_HDD_AUTO: SCSI #0 for .hdd, else IDE #1), then
 * offers to reset. */
#define KEYBAR_HDD_AUTO	0xff
void keybar_pickhdd(unsigned char drv);

/* Assigns an image (path relative to the data directory, NULL = none) to a
 * slot and offers to reset. */
void keybar_sethdd(unsigned char drv, const char *path);

/* Testing: taps the bar button with the given label ("f·1", "GRPH", ...),
 * or runs a menu command: "!reset", "!np2menu", "!eject1", "!eject2",
 * "!insert1:<path>", "!insert2:<path>", "!hide", "!show", "!softkbd",
 * "!softtype:<text>" (as if typed on the software keyboard),
 * "!hdd<drv>:<path>" / "!hdd<drv>" (set / remove a hard disk; drv in hex,
 * 00-01 IDE, 20-23 SCSI; takes effect at "!reset"),
 * "!importhdd<drv>:<absolute path>" (copy into hdd/ as if picked elsewhere),
 * "!dumphddmenu" (log the hard disk menu), "!settings", "!guide",
 * "!dismiss" (close what is presented), "!tap:<row title>" (on the settings screen),
 * "!newdisk:<index>:<MB>" (as on the new disk screen),
 * "!orient:portrait" / "!orient:landscape", "!showmenu" (open the ≡ menu),
 * "!dpad:up|down|left|right" (cross keys), "!dpad:toggle",
 * "!kbdkind:<pc98|system>" (choose and show a screen keyboard; "!softkbd"
 * toggles it), "!kbdtap:<key id>" (tap a key on the app's keyboard, see
 * kbdlayout.m), "!kbdblock:<n>" (its tab when paged). */
void keybar_debugcommand(const char *command);

#ifdef __cplusplus
}
#endif
