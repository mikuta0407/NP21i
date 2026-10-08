/**
 * @file	gamepad.h
 * @brief	Game controllers (MFi, Xbox, PlayStation...) as PC-98 keys or joystick
 */

#pragma once

#include "compiler.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>

/* What the controller's directions (and A / B) are (settings):
 * - arrow keys;
 * - the keypad's 8 / 2 / 4 / 6;
 * - the joystick port of the sound board (PC-9801-26K / 86 / 118 ...):
 *   directions, and A / B as triggers 1 / 2.
 * The other buttons are keys, by default X = SPACE, Y = RETURN, L = SHIFT,
 * R = CTRL, menu = ESC, options = f·1 (gamepad_setkeyindex). */
typedef NS_ENUM(NSInteger, NP2GamepadMode) {
	NP2GamepadModeArrows,
	NP2GamepadModeKeypad,
	NP2GamepadModeJoystick
};

/* Starts following controllers as they connect; the mode is read from the
 * settings whenever they change. */
void gamepad_initialize(void);

/* The buttons that can be set to a key (a, b, x, y, l, r, menu, options),
 * their names, the keys they can be ("なし", "Z", ...), and the one each is
 * (an index into those; settings, kept per environment). In joystick mode,
 * A and B are the triggers whatever they are set to. */
NSArray<NSString *> *gamepad_buttons(void);
NSString *gamepad_buttontitle(NSString *button);
NSArray<NSString *> *gamepad_keytitles(void);
NSInteger gamepad_keyindex(NSString *button);
void gamepad_setkeyindex(NSString *button, NSInteger choice);
void gamepad_resetkeys(void);

/* Testing: "!gp:<button>/<0|1>" holds or lets go of a button of a
 * controller that is not there: up, down, left, right, a, b, x, y, l, r,
 * menu, options. "!gpmode:<n>" sets the mode, "!gpkey:<button>/<key title>"
 * what a button is. */
BOOL gamepad_debugcommand(NSString *command);
#endif
