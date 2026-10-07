/**
 * @file	settings.m
 * @brief	App settings from the iOS Settings app (Settings.bundle)
 *
 * midi_output_latency_ms -> cmmidi_latency_ms (default 20, 0 = send immediately)
 *
 * The environment variable NP2_MIDI_LATENCY_MS overrides the setting
 * (for testing with simctl: SIMCTL_CHILD_NP2_MIDI_LATENCY_MS=0).
 */

#include "compiler.h"
#include "settings.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern UINT cmmidi_latency_ms;

static NSString *const kMidiLatencyKey = @"midi_output_latency_ms";

static void apply_settings(void)
{
	const char *env = getenv("NP2_MIDI_LATENCY_MS");
	if (env && env[0]) {
		cmmidi_latency_ms = (UINT)atoi(env);
		return;
	}
	NSInteger latency = MAX([[NSUserDefaults standardUserDefaults] integerForKey:kMidiLatencyKey], 0);
	if ((UINT)latency != cmmidi_latency_ms) {
		NSLog(@"settings: MIDI output latency %ld ms", (long)latency);
	}
	cmmidi_latency_ms = (UINT)latency;
}

void settings_initialize(void)
{
	/* Settings.bundle defaults are not visible to the app until the user
	 * opens the Settings app, so register them here as well. */
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{ kMidiLatencyKey: @20 }];
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
