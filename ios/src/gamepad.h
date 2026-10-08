/**
 * @file	gamepad.h
 * @brief	Game controllers (MFi, Xbox, PlayStation...) as PC-98 keys or joystick
 */

#pragma once

#include "compiler.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>

/* What the controller's directions and A / B are (settings):
 * - arrow keys, A = Z, B = X;
 * - the keypad's 8 / 2 / 4 / 6, A = Z, B = X;
 * - the joystick port of the sound board (PC-9801-26K / 86 / 118 ...):
 *   directions and triggers 1 / 2.
 * The other buttons are always keys: X = SPACE, Y = RETURN, L = SHIFT,
 * R = CTRL, menu = ESC, options = f·1. */
typedef NS_ENUM(NSInteger, NP2GamepadMode) {
	NP2GamepadModeArrows,
	NP2GamepadModeKeypad,
	NP2GamepadModeJoystick
};

/* Starts following controllers as they connect; the mode is read from the
 * settings whenever they change. */
void gamepad_initialize(void);

/* Testing: "!gp:<button>/<0|1>" holds or lets go of a button of a
 * controller that is not there: up, down, left, right, a, b, x, y, l, r,
 * menu, options. "!gpmode:<n>" sets the mode. */
BOOL gamepad_debugcommand(NSString *command);
#endif
