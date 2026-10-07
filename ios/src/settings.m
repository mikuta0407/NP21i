/**
 * @file	settings.m
 * @brief	App settings from the iOS Settings app (Settings.bundle)
 *
 * midi_output_latency_ms -> cmmidi_latency_ms (default 20, 0 = send immediately)
 * midi_input_latency_ms  -> cmmidi_midiin_latency_ms (default 20, 0 = deliver immediately)
 *
 * The environment variables NP2_MIDI_LATENCY_MS / NP2_MIDIIN_LATENCY_MS
 * override the settings (for testing with simctl: SIMCTL_CHILD_NP2_...=0).
 */

#include "compiler.h"
#include "settings.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern UINT cmmidi_latency_ms;
extern UINT cmmidi_midiin_latency_ms;

static NSString *const kMidiLatencyKey = @"midi_output_latency_ms";
static NSString *const kMidiInLatencyKey = @"midi_input_latency_ms";

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
	apply_ms(&cmmidi_latency_ms, read_ms(kMidiLatencyKey, "NP2_MIDI_LATENCY_MS"), "MIDI output latency");
	apply_ms(&cmmidi_midiin_latency_ms, read_ms(kMidiInLatencyKey, "NP2_MIDIIN_LATENCY_MS"), "MIDI input latency");
}

void settings_initialize(void)
{

	/* Settings.bundle defaults are not visible to the app until the user
	 * opens the Settings app, so register them here as well. */
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{ kMidiLatencyKey: @20, kMidiInLatencyKey: @20 }];
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
