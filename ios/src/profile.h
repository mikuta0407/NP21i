/**
 * @file	profile.h
 * @brief	Environments: sets of machine settings and disks to switch between
 */

#pragma once

#import <Foundation/Foundation.h>

/* An environment is what NP2 keeps in np21kai.cfg (machine, sound board,
 * hard disks, MIDI ports...), the state saved to resume (np2.sav), and the
 * floppies in the drives; e.g. one for Recomposer, one for a game, each
 * with its own hard disk. The one in use has its files in the data
 * directory, where NP2 reads them; the others are kept in
 * profiles/<id>/. Switching saves the one in use there, and loads the other
 * as at start: resumed where it was left, or reset with its floppies. */

/* How a new environment gets its hard disks. */
typedef NS_ENUM(NSInteger, NP2ProfileDisks) {
	NP2ProfileDisksCopy,		/* copies of the images in use (cloned: no space taken until written) */
	NP2ProfileDisksShare,		/* the same images */
	NP2ProfileDisksNone			/* none: to make or choose new ones */
};

/* Posted after a switch, or a change in the list. */
extern NSNotificationName const NP2ProfilesChanged;

/* Call before the emulator starts: the first time, the files in use become
 * the environment "標準". */
void profile_initialize(void);

/* The environments, oldest first, and the one in use. */
NSArray<NSString *> *profile_ids(void);
NSString *profile_active(void);
NSString *profile_name(NSString *identifier);
/* The hard disk images it uses ("SCSI #0: recomposer.hdd"...). */
NSArray<NSString *> *profile_disks(NSString *identifier);

/* Saves the environment in use and loads another (resets the PC-98). */
void profile_switch(NSString *identifier);

/* A new environment like the one in use (machine settings, MIDI...),
 * without its floppies or saved state; returns its identifier, or nil. */
NSString *profile_create(NSString *name, NP2ProfileDisks disks, NSError **error);

void profile_rename(NSString *identifier, NSString *name);
/* Not the one in use. Its hard disk images are left in hdd/. */
void profile_delete(NSString *identifier);
