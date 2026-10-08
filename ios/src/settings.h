/**
 * @file	settings.h
 * @brief	App settings (NSUserDefaults), shared by the Settings app
 *			(Settings.bundle) and the in-app settings screen
 */

#pragma once

#include "compiler.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>

extern NSString *const kSettingMidiOutputLatency;	/* ms, 0 = immediately */
extern NSString *const kSettingMidiInputLatency;	/* ms, 0 = immediately */
extern NSString *const kSettingKeyboardLayout;		/* KEYLAYOUT_JIS / KEYLAYOUT_US */
extern NSString *const kSettingRunInBackground;		/* BOOL */
extern NSString *const kSettingResume;				/* BOOL */
extern NSString *const kSettingShowSpeed;			/* BOOL */
extern NSString *const kSettingScreenKeyboard;		/* kScreenKeyboardSystem or an NP2KeyboardLayout identifier */
extern NSString *const kScreenKeyboardSystem;		/* the iOS software keyboard */
extern NSString *const kSettingKeyHaptics;			/* BOOL: the app's keyboard taps back */
extern NSString *const kSettingKeyPreview;			/* BOOL: the app's keyboard shows pressed characters larger */
extern NSString *const kSettingLandscapeFold;		/* half open and wider than tall: 0 keyboard below, 1 screen left, 2 screen right */
extern NSString *const kSettingGamepad;			/* NP2GamepadMode (gamepad.h) */
extern NSString *const kSettingGamepadMap;			/* button name -> PC-98 key code (gamepad.m) */
extern NSString *const kSettingMouseLock;			/* BOOL: a connected mouse's pointer stays in the app */
extern NSString *const kSettingPinchZoom;			/* BOOL: two fingers zoom the screen */
extern NSString *const kSettingTrackpad;			/* BOOL: touches on the screen are a trackpad's */
extern NSString *const kSettingTrackpadSpeed;		/* % of a finger's travel, 100 = alike */

/* The choices for the trackpad speed, in %. */
NSArray<NSNumber *> *settings_trackpadspeeds(void);

/* What the keyboard button shows: kScreenKeyboardSystem or a layout identifier. */
NSString *settings_screenkeyboard(void);
/* The choices for it, in menu order, and their names. */
NSArray<NSString *> *settings_screenkeyboards(void);
NSString *settings_screenkeyboardtitle(NSString *identifier);
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Loads the settings and keeps them applied when they change. */
void settings_initialize(void);

BOOL settings_runinbackground(void);
BOOL settings_resume(void);
BOOL settings_showspeed(void);
BOOL settings_keyhaptics(void);
BOOL settings_keypreview(void);
NSInteger settings_landscapefold(void);
/* The choices for it, in order of its values. */
NSArray<NSString *> *settings_landscapefolds(void);
NSInteger settings_gamepadmode(void);
NSArray<NSString *> *settings_gamepadmodes(void);
BOOL settings_mouselock(void);
BOOL settings_pinchzoom(void);
BOOL settings_trackpad(void);
/* The trackpad speed as a factor (1 = the pointer travels as the finger). */
double settings_trackpadspeed(void);

/* Saves np2cfg / np2oscfg (np21kai.cfg) after they were changed. */
void settings_savenp2cfg(void);

#ifdef __cplusplus
}
#endif
