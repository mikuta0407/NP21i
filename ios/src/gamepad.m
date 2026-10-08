/**
 * @file	gamepad.m
 * @brief	Game controllers (MFi, Xbox, PlayStation...) as PC-98 keys or joystick
 *
 * GameController calls back on the main queue, where the emulator also
 * runs. What all connected controllers hold is merged into one set of
 * buttons; a button that changes presses or releases its key, or changes
 * the joystick port's bits (read by the sound boards through
 * joymng_getstat(), NP2kai patch 0011).
 */

#include "gamepad.h"
#include "keyinput.h"
#include "settings.h"
#include <joymng.h>

#import <GameController/GameController.h>

enum {
	GP_UP		= 1 << 0,
	GP_DOWN		= 1 << 1,
	GP_LEFT		= 1 << 2,
	GP_RIGHT	= 1 << 3,
	GP_A		= 1 << 4,
	GP_B		= 1 << 5,
	GP_X		= 1 << 6,
	GP_Y		= 1 << 7,
	GP_L		= 1 << 8,
	GP_R		= 1 << 9,
	GP_MENU		= 1 << 10,
	GP_OPTIONS	= 1 << 11,
	GP_COUNT	= 12
};

static const char *const s_names[GP_COUNT] = {
	"up", "down", "left", "right", "a", "b", "x", "y", "l", "r", "menu", "options"
};

/* PC-98 joystick bits: 0 while held. A trigger clears its rapid bit too, so
 * that both the PSG port (bits 4, 5) and the 118's game port (6, 7) see it. */
static const UINT8 s_joybits[6] = {
	JOY_UP_BIT, JOY_DOWN_BIT, JOY_LEFT_BIT, JOY_RIGHT_BIT,
	JOY_BTN1_BIT | JOY_RAPIDBTN1_BIT, JOY_BTN2_BIT | JOY_RAPIDBTN2_BIT
};

static NP2GamepadMode s_mode;
static UINT s_held;			/* from the controllers */
static UINT s_debugHeld;	/* from debug commands */
static UINT s_applied;		/* pressed as keys or joystick bits */
static UINT8 s_joy = 0xff;

/* The key for a button in a mode, or 0xff when it is a joystick bit. */
static UINT8 key_for(int index, NP2GamepadMode mode)
{
	static const UINT8 arrows[4] = { PC98KEY_UP, PC98KEY_DOWN, PC98KEY_LEFT, PC98KEY_RIGHT };
	static const UINT8 keypad[4] = { 0x43, 0x4b, 0x46, 0x48 };		/* <8> <2> <4> <6> */
	static const UINT8 others[GP_COUNT - 4] = {
		0x29, 0x2a,							/* A = Z, B = X */
		PC98KEY_SPACE, PC98KEY_RETURN,		/* X, Y */
		PC98KEY_SHIFT, PC98KEY_CTRL,		/* L, R */
		PC98KEY_ESC, PC98KEY_F1				/* menu, options */
	};
	if (mode == NP2GamepadModeJoystick && index < 6) {
		return 0xff;
	}
	if (index < 4) {
		return (mode == NP2GamepadModeKeypad) ? keypad[index] : arrows[index];
	}
	return others[index - 4];
}

static void set_button(int index, BOOL down, NP2GamepadMode mode)
{
	UINT8 key = key_for(index, mode);
	if (key == 0xff) {
		if (down) {
			s_joy &= (UINT8)~s_joybits[index];
		}
		else {
			s_joy |= s_joybits[index];
		}
	}
	else if (down) {
		keyinput_down(key);
	}
	else {
		keyinput_up(key);
	}
}

static void apply(void)
{
	UINT held = s_held | s_debugHeld;
	UINT changed = held ^ s_applied;
	for (int i = 0; i < GP_COUNT; i++) {
		if (changed & (1u << i)) {
			set_button(i, (held >> i) & 1, s_mode);
		}
	}
	s_applied = held;
}

static void set_mode(NP2GamepadMode mode)
{
	if (mode == s_mode) {
		return;
	}
	/* let go in the old mode, press again in the new one */
	for (int i = 0; i < GP_COUNT; i++) {
		if (s_applied & (1u << i)) {
			set_button(i, NO, s_mode);
		}
	}
	s_applied = 0;
	s_mode = mode;
	apply();
}

static BOOL pressed(GCControllerButtonInput *button)
{
	return button.isPressed;
}

static UINT held_on(GCController *controller)
{
	UINT held = 0;
	GCExtendedGamepad *pad = controller.extendedGamepad;
	if (pad) {
		GCControllerDirectionPad *dpad = pad.dpad;
		GCControllerDirectionPad *stick = pad.leftThumbstick;
		if (pressed(dpad.up) || stick.yAxis.value > 0.5) held |= GP_UP;
		if (pressed(dpad.down) || stick.yAxis.value < -0.5) held |= GP_DOWN;
		if (pressed(dpad.left) || stick.xAxis.value < -0.5) held |= GP_LEFT;
		if (pressed(dpad.right) || stick.xAxis.value > 0.5) held |= GP_RIGHT;
		if (pressed(pad.buttonA)) held |= GP_A;
		if (pressed(pad.buttonB)) held |= GP_B;
		if (pressed(pad.buttonX)) held |= GP_X;
		if (pressed(pad.buttonY)) held |= GP_Y;
		if (pressed(pad.leftShoulder) || pressed(pad.leftTrigger)) held |= GP_L;
		if (pressed(pad.rightShoulder) || pressed(pad.rightTrigger)) held |= GP_R;
		if (pressed(pad.buttonMenu)) held |= GP_MENU;
		if (pad.buttonOptions && pressed(pad.buttonOptions)) held |= GP_OPTIONS;
		return held;
	}
	GCMicroGamepad *micro = controller.microGamepad;
	if (micro) {
		if (pressed(micro.dpad.up)) held |= GP_UP;
		if (pressed(micro.dpad.down)) held |= GP_DOWN;
		if (pressed(micro.dpad.left)) held |= GP_LEFT;
		if (pressed(micro.dpad.right)) held |= GP_RIGHT;
		if (pressed(micro.buttonA)) held |= GP_A;
		if (pressed(micro.buttonX)) held |= GP_B;
		if (pressed(micro.buttonMenu)) held |= GP_MENU;
	}
	return held;
}

static void refresh(void)
{
	UINT held = 0;
	for (GCController *controller in GCController.controllers) {
		held |= held_on(controller);
	}
	s_held = held;
	apply();
}

static void follow(GCController *controller)
{
	controller.handlerQueue = dispatch_get_main_queue();
	if (controller.extendedGamepad) {
		controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
			refresh();
		};
	}
	else if (controller.microGamepad) {
		controller.microGamepad.valueChangedHandler = ^(GCMicroGamepad *gamepad, GCControllerElement *element) {
			refresh();
		};
	}
	NSLog(@"gamepad: %@ connected", controller.vendorName ?: @"controller");
}

void gamepad_initialize(void)
{
	s_mode = (NP2GamepadMode)settings_gamepadmode();
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
	            usingBlock:^(NSNotification *note) {
		follow(note.object);
		refresh();
	}];
	[nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
	            usingBlock:^(NSNotification *note) {
		refresh();
	}];
	[nc addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
	            usingBlock:^(NSNotification *note) {
		set_mode((NP2GamepadMode)settings_gamepadmode());
	}];
	for (GCController *controller in GCController.controllers) {
		follow(controller);
	}
	refresh();
}

BOOL gamepad_debugcommand(NSString *command)
{
	if ([command hasPrefix:@"!gpmode:"]) {
		[[NSUserDefaults standardUserDefaults] setInteger:[command substringFromIndex:8].integerValue forKey:kSettingGamepad];
		set_mode((NP2GamepadMode)settings_gamepadmode());
		return YES;
	}
	if (![command hasPrefix:@"!gp:"]) {
		return NO;
	}
	NSArray<NSString *> *args = [[command substringFromIndex:4] componentsSeparatedByString:@"/"];
	for (int i = 0; i < GP_COUNT; i++) {
		if ([args[0] isEqualToString:@(s_names[i])]) {
			if (args.count > 1 && args[1].intValue) {
				s_debugHeld |= 1u << i;
			}
			else {
				s_debugHeld &= ~(1u << i);
			}
			apply();
			NSLog(@"gamepad: %@ -> joy %02x", command, s_joy);
			return YES;
		}
	}
	NSLog(@"gamepad: no button %@", args[0]);
	return YES;
}

// ---- NP2kai's joystick (patch 0011)

REG8 joymng_getstat(void)
{
	return (s_mode == NP2GamepadModeJoystick) ? s_joy : 0xff;
}

REG8 joymng_available(void)
{
	return (s_mode == NP2GamepadModeJoystick) ? 1 : 0;
}
