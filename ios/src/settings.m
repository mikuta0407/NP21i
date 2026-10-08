/**
 * @file	settings.m
 * @brief	App settings from the iOS Settings app (Settings.bundle)
 *
 * midi_output_latency_ms -> cmmidi_latency_ms (default 20, 0 = send immediately)
 * midi_input_latency_ms  -> cmmidi_midiin_latency_ms (default 20, 0 = deliver immediately)
 * keyboard_layout        -> keyinput_setlayout() (0 = JIS, 1 = US; default JIS)
 * run_in_background, resume_state -> lifecycle.m; show_speed_warning, screen_keyboard,
 * trackpad_mouse, trackpad_speed, key_haptics, key_preview -> keybar.m
 *
 * The environment variables NP2_MIDI_LATENCY_MS / NP2_MIDIIN_LATENCY_MS
 * override the settings (for testing with simctl: SIMCTL_CHILD_NP2_...=0).
 */

#include "compiler.h"
#include "settings.h"
#include "keyinput.h"
#include "kbdlayout.h"
#include <sysmng.h>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern UINT cmmidi_latency_ms;
extern UINT cmmidi_midiin_latency_ms;

NSString *const kSettingMidiOutputLatency = @"midi_output_latency_ms";
NSString *const kSettingMidiInputLatency = @"midi_input_latency_ms";
NSString *const kSettingKeyboardLayout = @"keyboard_layout";
NSString *const kSettingRunInBackground = @"run_in_background";
NSString *const kSettingResume = @"resume_state";
NSString *const kSettingShowSpeed = @"show_speed_warning";
NSString *const kSettingScreenKeyboard = @"screen_keyboard";
NSString *const kScreenKeyboardSystem = @"system";
NSString *const kSettingKeyHaptics = @"key_haptics";
NSString *const kSettingKeyPreview = @"key_preview";
NSString *const kSettingTrackpad = @"trackpad_mouse";
NSString *const kSettingTrackpadSpeed = @"trackpad_speed";

/* Value from the environment (testing) or the user defaults. */
static UINT read_ms(NSString *key, const char *env)
{
	const char *value = getenv(env);
	if (value && value[0]) {
		return (UINT)atoi(value);
	}
	return (UINT)MAX([[NSUserDefaults standardUserDefaults] integerForKey:key], 0);
}

static void apply_ms(UINT *target, UINT value, const char *name)
{
	if (*target != value) {
		NSLog(@"settings: %s %u ms", name, value);
	}
	*target = value;
}

static void apply_settings(void)
{
	apply_ms(&cmmidi_latency_ms, read_ms(kSettingMidiOutputLatency, "NP2_MIDI_LATENCY_MS"), "MIDI output latency");
	apply_ms(&cmmidi_midiin_latency_ms, read_ms(kSettingMidiInputLatency, "NP2_MIDIIN_LATENCY_MS"), "MIDI input latency");

	static int layout = -1;
	int newlayout = (int)[[NSUserDefaults standardUserDefaults] integerForKey:kSettingKeyboardLayout];
	if (layout != newlayout) {
		NSLog(@"settings: keyboard layout %s", (newlayout == KEYLAYOUT_US) ? "US" : "JIS");
		layout = newlayout;
		keyinput_setlayout(layout);
	}
}

BOOL settings_runinbackground(void)
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingRunInBackground];
}

BOOL settings_resume(void)
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingResume];
}

BOOL settings_showspeed(void)
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingShowSpeed];
}

BOOL settings_keyhaptics(void)
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingKeyHaptics];
}

BOOL settings_keypreview(void)
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingKeyPreview];
}

BOOL settings_trackpad(void)
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingTrackpad];
}

NSArray<NSNumber *> *settings_trackpadspeeds(void)
{
	return @[ @50, @75, @100, @150, @200, @300 ];
}

double settings_trackpadspeed(void)
{
	NSInteger percent = [[NSUserDefaults standardUserDefaults] integerForKey:kSettingTrackpadSpeed];
	return (percent > 0) ? percent / 100.0 : 1;
}

NSString *settings_screenkeyboard(void)
{
	return [[NSUserDefaults standardUserDefaults] stringForKey:kSettingScreenKeyboard] ?: kScreenKeyboardSystem;
}

NSArray<NSString *> *settings_screenkeyboards(void)
{
	NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
	for (NP2KeyboardLayout *layout in [NP2KeyboardLayout allLayouts]) {
		[identifiers addObject:layout.identifier];
	}
	[identifiers addObject:kScreenKeyboardSystem];
	return identifiers;
}

NSString *settings_screenkeyboardtitle(NSString *identifier)
{
	if ([identifier isEqualToString:kScreenKeyboardSystem]) {
		return @"iOS のキーボード";
	}
	return [NP2KeyboardLayout layoutWithIdentifier:identifier].title ?: identifier;
}

void settings_savenp2cfg(void)
{
	sysmng_update(SYS_UPDATECFG | SYS_UPDATEOSCFG);
}

void settings_initialize(void)
{

	/* Settings.bundle defaults are not visible to the app until the user
	 * opens the Settings app, so register them here as well. */
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{ kSettingMidiOutputLatency: @20, kSettingMidiInputLatency: @20, kSettingKeyboardLayout: @(KEYLAYOUT_JIS),
		kSettingRunInBackground: @YES, kSettingResume: @YES, kSettingShowSpeed: @YES,
		kSettingScreenKeyboard: @"pc98", kSettingTrackpadSpeed: @100,
		kSettingKeyHaptics: @YES, kSettingKeyPreview: @YES }];
	apply_settings();
	/* Changes made in the Settings app arrive while the app is in the
	 * background, so re-read them when it becomes active again. */
	for (NSNotificationName name in @[ NSUserDefaultsDidChangeNotification, UIApplicationDidBecomeActiveNotification ]) {
		[[NSNotificationCenter defaultCenter] addObserverForName:name
		                                                  object:nil
		                                                   queue:nil
		                                              usingBlock:^(NSNotification *note) {
			(void)note;
			apply_settings();
		}];
	}
}
