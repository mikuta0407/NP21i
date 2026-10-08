/**
 * @file	settingsview.h
 * @brief	In-app settings screen and the first-run guide
 */

#pragma once

#import <UIKit/UIKit.h>

/* Shows the settings screen over `host`. */
void settingsview_present(UIViewController *host);

/* Shows the settings screen at its environments. */
void settingsview_presentprofiles(UIViewController *host);
/* Switches to an environment, asking first when the state would be lost. */
void settingsview_switchprofile(UIViewController *host, NSString *identifier);

/* Shows the guide when there is nothing to boot (no hard disk, no floppy). */
void settingsview_presentguideifneeded(UIViewController *host);
void settingsview_presentguide(UIViewController *host);

/* Testing: acts as if the row with this title on the visible settings
 * screen was tapped. */
void settingsview_debugtap(const char *title);
/* Testing: creates a new disk as listed on the new disk screen (index from 0). */
void settingsview_debugnewdisk(int index, unsigned int sizemb);
