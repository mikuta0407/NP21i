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

#define KEY_NONE	0xfe		/* a button that does nothing */
#define KEY_JOY		0xff		/* a joystick bit */

/* What A, B, X, Y, L, R, menu and options are as keys (settings). */
static const UINT8 s_defaultmap[GP_COUNT - 4] = {
	0x29, 0x2a,							/* A = Z, B = X */
	PC98KEY_SPACE, PC98KEY_RETURN,		/* X, Y */
	PC98KEY_SHIFT, PC98KEY_CTRL,		/* L, R */
	PC98KEY_ESC, PC98KEY_F1				/* menu, options */
};
static UINT8 s_map[GP_COUNT - 4];

static NP2GamepadMode s_mode;
static UINT s_held;			/* from the controllers */
static UINT s_debugHeld;	/* from debug commands */
static UINT s_applied;		/* pressed as keys or joystick bits */
static UINT8 s_joy = 0xff;

/* The key for a button in a mode and map, KEY_JOY or KEY_NONE. */
static UINT8 key_for(int index, NP2GamepadMode mode, const UINT8 *map)
{
	static const UINT8 arrows[4] = { PC98KEY_UP, PC98KEY_DOWN, PC98KEY_LEFT, PC98KEY_RIGHT };
	static const UINT8 keypad[4] = { 0x43, 0x4b, 0x46, 0x48 };		/* <8> <2> <4> <6> */
	if (mode == NP2GamepadModeJoystick && index < 6) {
		return KEY_JOY;
	}
	if (index < 4) {
		return (mode == NP2GamepadModeKeypad) ? keypad[index] : arrows[index];
	}
	return map[index - 4];
}

static void set_button(int index, BOOL down, NP2GamepadMode mode, const UINT8 *map)
{
	UINT8 key = key_for(index, mode, map);
	if (key == KEY_NONE) {
		return;
	}
	if (key == KEY_JOY) {
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
			set_button(i, (held >> i) & 1, s_mode, s_map);
		}
	}
	s_applied = held;
}

static void load_map(UINT8 *map)
{
	NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSettingGamepadMap];
	for (int i = 4; i < GP_COUNT; i++) {
		NSNumber *code = saved[@(s_names[i])];
		map[i - 4] = code ? (UINT8)code.unsignedIntValue : s_defaultmap[i - 4];
	}
}

/* The mode and map from the settings: what is held is let go as it was
 * and pressed again as it is now. */
static void reconfigure(void)
{
	NP2GamepadMode mode = (NP2GamepadMode)settings_gamepadmode();
	UINT8 map[GP_COUNT - 4];
	load_map(map);
	if (mode == s_mode && memcmp(map, s_map, sizeof(map)) == 0) {
		return;
	}
	for (int i = 0; i < GP_COUNT; i++) {
		if (s_applied & (1u << i)) {
			set_button(i, NO, s_mode, s_map);
		}
	}
	s_applied = 0;
	s_mode = mode;
	memcpy(s_map, map, sizeof(map));
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
	load_map(s_map);
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
		reconfigure();
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
		reconfigure();
		return YES;
	}
	if ([command hasPrefix:@"!gpkey:"]) {
		/* "!gpkey:<button>/<key title>" */
		NSArray<NSString *> *args = [[command substringFromIndex:7] componentsSeparatedByString:@"/"];
		NSUInteger index = (args.count > 1) ? [gamepad_keytitles() indexOfObject:args[1]] : NSNotFound;
		if (index != NSNotFound) {
			gamepad_setkeyindex(args[0], (NSInteger)index);
			reconfigure();
		}
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

// ---- settings

NSArray<NSString *> *gamepad_buttons(void)
{
	NSMutableArray<NSString *> *buttons = [NSMutableArray array];
	for (int i = 4; i < GP_COUNT; i++) {
		[buttons addObject:@(s_names[i])];
	}
	return buttons;
}

NSString *gamepad_buttontitle(NSString *button)
{
	NSDictionary<NSString *, NSString *> *titles = @{
		@"a": @"A", @"b": @"B", @"x": @"X", @"y": @"Y", @"l": @"L（L1・L2）", @"r": @"R（R1・R2）",
		@"menu": @"メニュー", @"options": @"オプション",
	};
	return titles[button] ?: button;
}

/* The keys a button can be. */
static NSArray<NSArray *> *key_choices(void)
{
	static NSArray<NSArray *> *choices;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableArray<NSArray *> *list = [NSMutableArray arrayWithArray:@[
			@[ @"なし", @(KEY_NONE) ],
			@[ @"Z", @0x29 ], @[ @"X", @0x2a ], @[ @"C", @0x2b ], @[ @"V", @0x2c ],
			@[ @"A", @0x1d ], @[ @"S", @0x1e ], @[ @"D", @0x1f ], @[ @"Q", @0x10 ], @[ @"W", @0x11 ], @[ @"E", @0x12 ],
			@[ @"Y", @0x15 ], @[ @"N", @0x2e ],
			@[ @"スペース", @(PC98KEY_SPACE) ], @[ @"リターン", @(PC98KEY_RETURN) ], @[ @"ESC", @(PC98KEY_ESC) ],
			@[ @"TAB", @(PC98KEY_TAB) ], @[ @"BS", @(PC98KEY_BS) ], @[ @"STOP", @(PC98KEY_STOP) ],
			@[ @"SHIFT", @(PC98KEY_SHIFT) ], @[ @"CTRL", @(PC98KEY_CTRL) ], @[ @"GRPH", @(PC98KEY_GRPH) ],
			@[ @"XFER", @(PC98KEY_XFER) ], @[ @"NFER", @(PC98KEY_NFER) ],
			@[ @"↑", @(PC98KEY_UP) ], @[ @"↓", @(PC98KEY_DOWN) ], @[ @"←", @(PC98KEY_LEFT) ], @[ @"→", @(PC98KEY_RIGHT) ],
		]];
		for (int i = 0; i < 10; i++) {
			[list addObject:@[ [NSString stringWithFormat:@"f·%d", i + 1], @(PC98KEY_F1 + i) ]];
		}
		for (int i = 1; i <= 9; i++) {
			[list addObject:@[ [NSString stringWithFormat:@"%d", i], @(i) ]];
		}
		[list addObject:@[ @"0", @0x0a ]];
		choices = list;
	});
	return choices;
}

NSArray<NSString *> *gamepad_keytitles(void)
{
	NSMutableArray<NSString *> *titles = [NSMutableArray array];
	for (NSArray *choice in key_choices()) {
		[titles addObject:choice[0]];
	}
	return titles;
}

static NSInteger button_index(NSString *button)
{
	for (int i = 4; i < GP_COUNT; i++) {
		if ([button isEqualToString:@(s_names[i])]) {
			return i - 4;
		}
	}
	return -1;
}

NSInteger gamepad_keyindex(NSString *button)
{
	NSInteger index = button_index(button);
	if (index < 0) {
		return -1;
	}
	UINT8 map[GP_COUNT - 4];
	load_map(map);
	NSArray<NSArray *> *choices = key_choices();
	for (NSUInteger i = 0; i < choices.count; i++) {
		if ([choices[i][1] unsignedIntValue] == map[index]) {
			return (NSInteger)i;
		}
	}
	return -1;
}

void gamepad_setkeyindex(NSString *button, NSInteger choice)
{
	NSArray<NSArray *> *choices = key_choices();
	if (button_index(button) < 0 || choice < 0 || choice >= (NSInteger)choices.count) {
		return;
	}
	NSMutableDictionary *saved = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kSettingGamepadMap] mutableCopy]
		?: [NSMutableDictionary dictionary];
	saved[button] = choices[(NSUInteger)choice][1];
	[[NSUserDefaults standardUserDefaults] setObject:saved forKey:kSettingGamepadMap];
}

void gamepad_resetkeys(void)
{
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:kSettingGamepadMap];
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
