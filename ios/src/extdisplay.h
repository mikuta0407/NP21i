/**
 * @file	extdisplay.h
 * @brief	The PC-98 screen on an external display (TV, monitor, AirPlay)
 *
 * Info.plist gives external display scenes to NP2ExternalSceneDelegate,
 * which shows the PC-98 screen there, as large as fits, in the screen style
 * of the settings. Meanwhile the device's own screen works as a trackpad
 * (keybar.m), since its picture is not where one looks.
 */

#pragma once

#import <Foundation/Foundation.h>

/* Posted when a display is connected or disconnected. */
extern NSNotificationName const NP2ExternalDisplayChanged;

BOOL extdisplay_isconnected(void);

/* Testing: shows the external display's view in a window over the app
 * (the simulator cannot connect one without its GUI). */
void extdisplay_debugshow(BOOL show);
