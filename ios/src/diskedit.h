/**
 * @file	diskedit.h
 * @brief	Screens for the files in disk images, and setting up the host drive
 */

#pragma once

#import <UIKit/UIKit.h>

/* Lists the disk images (those in use first); one can be opened to see,
 * add, export, rename and delete its files. */
void diskedit_present(UIViewController *host);

/* Makes Z: usable in one go: copies HOSTDRV.COM to the boot disk, adds it
 * to AUTOEXEC.BAT and LASTDRIVE=Z to CONFIG.SYS (FreeDOS: FDCONFIG.SYS)
 * where missing, turns the host drive on and resets, after asking. */
void diskedit_setuphostdrive(UIViewController *host);

/* Testing: "!diskedit" (show the list), "!disktap:<row title>" (tap a row
 * on the top disk screen), "!diskimport:<path>" (add a host file or folder,
 * absolute or relative to the data directory, to the directory shown), "!diskmkdir:<name>",
 * "!diskdelete:<name>", "!diskdone" (close, as Done),
 * "!hostdrvsetup" (diskedit_setuphostdrive, confirmed). Returns NO for
 * other commands. */
BOOL diskedit_debugcommand(NSString *command);
