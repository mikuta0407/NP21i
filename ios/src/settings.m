/**
 * @file	settings.m
 * @brief	App settings from the iOS Settings app (Settings.bundle)
 *
 * midi_output_latency_ms -> cmmidi_latency_ms (default 20, 0 = send immediately)
 * midi_input_latency_ms  -> cmmidi_midiin_latency_ms (default 20, 0 = deliver immediately)
 * keyboard_layout        -> keyinput_setlayout() (0 = JIS, 1 = US; default JIS)
 * run_in_background, resume_state -> lifecycle.m; show_speed_warning -> keybar.m
 *
 * The environment variables NP2_MIDI_LATENCY_MS / NP2_MIDIIN_LATENCY_MS
 * override the settings (for testing with simctl: SIMCTL_CHILD_NP2_...=0).
 */

#include "compiler.h"
#include "settings.h"
#include "keyinput.h"
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

void settings_savenp2cfg(void)
{
	sysmng_update(SYS_UPDATECFG | SYS_UPDATEOSCFG);
}

void settings_initialize(void)
{

	/* Settings.bundle defaults are not visible to the app until the user
	 * opens the Settings app, so register them here as well. */
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{ kSettingMidiOutputLatency: @20, kSettingMidiInputLatency: @20, kSettingKeyboardLayout: @(KEYLAYOUT_JIS),
		kSettingRunInBackground: @YES, kSettingResume: @YES, kSettingShowSpeed: @YES }];
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
