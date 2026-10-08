/**
 * @file	extdisplay.h
 * @brief	The PC-98 screen on an external display (TV, monitor, AirPlay)
 *
 * Info.plist gives external display scenes to NP2ExternalSceneDelegate,
 * which shows the PC-98 screen there, as large as fits, in the screen style
 * of the settings. Meanwhile the device's own screen works as a trackpad
 * (keybar.m), since its picture is not where one looks. Set to mirror, the
 * scene shows no window, and iOS mirrors the device's screen instead.
 */

#pragma once

#import <Foundation/Foundation.h>

extern NSString *const kSettingExternalDisplay;	/* NP2ExternalDisplayMode */

typedef NS_ENUM(NSInteger, NP2ExternalDisplayMode) {
	NP2ExternalDisplayScreen,	/* the PC-98 screen alone, the device a trackpad */
	NP2ExternalDisplayMirror	/* iOS mirrors the device's screen */
};

NP2ExternalDisplayMode extdisplay_mode(void);
NSArray<NSString *> *extdisplay_modes(void);	/* their names, in order */

/* Posted when a display is connected or disconnected, or starts or stops
 * showing the PC-98 screen. */
extern NSNotificationName const NP2ExternalDisplayChanged;

/* Whether a display shows the PC-98 screen (not mirroring). */
BOOL extdisplay_isconnected(void);

/* Testing: shows the external display's view in a window over the app
 * (the simulator cannot connect one without its GUI). */
void extdisplay_debugshow(BOOL show);
