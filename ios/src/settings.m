/**
 * @file	settings.m
 * @brief	App settings from the iOS Settings app (Settings.bundle)
 *
 * midi_output_latency_ms -> cmmidi_latency_ms (default 20, 0 = send immediately)
 * midi_input_latency_ms  -> cmmidi_midiin_latency_ms (default 20, 0 = deliver immediately)
 * keyboard_layout        -> keyinput_setlayout() (0 = JIS, 1 = US; default JIS)
 * midi_clock_out         -> mpu98ii_midiclockout (NP2kai patch 0015)
 * volume_master          -> np2cfg.vol_master (the other volumes are in np21kai.cfg)
 * run_in_background, resume_state -> lifecycle.m; show_speed_warning, screen_keyboard,
 * trackpad_mouse, trackpad_speed, key_haptics, key_preview, fold_landscape, mouse_lock, pinch_zoom, screen_style -> keybar.m;
 * gamepad_mode, gamepad_map -> gamepad.m
 *
 * The environment variables NP2_MIDI_LATENCY_MS / NP2_MIDIIN_LATENCY_MS
 * override the settings (for testing with simctl: SIMCTL_CHILD_NP2_...=0).
 */

#include "compiler.h"
#include "settings.h"
#include "keyinput.h"
#include "kbdlayout.h"
#include "synth.h"
#include <sysmng.h>
#include <pccore.h>
#include <nevent.h>
#include <cbus/mpu98ii.h>
#include <sound/sound.h>
#include <sound/beep.h>
#include <sound/opngen.h>
#include <sound/psggen.h>
#include <sound/rhythm.h>
#include <sound/adpcm.h>
#include <sound/pcm86.h>
#include <sound/oplgen.h>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern UINT cmmidi_latency_ms;
extern UINT cmmidi_midiin_latency_ms;

NSString *const kSettingMidiOutputLatency = @"midi_output_latency_ms";
NSString *const kSettingMidiInputLatency = @"midi_input_latency_ms";
NSString *const kSettingMidiClockOut = @"midi_clock_out";
NSString *const kSettingKeyboardLayout = @"keyboard_layout";
NSString *const kSettingRunInBackground = @"run_in_background";
NSString *const kSettingResume = @"resume_state";
NSString *const kSettingShowSpeed = @"show_speed_warning";
NSString *const kSettingScreenKeyboard = @"screen_keyboard";
NSString *const kScreenKeyboardSystem = @"system";
NSString *const kSettingScreenKeyboardShown = @"screen_keyboard_shown";
NSString *const kSettingKeyHaptics = @"key_haptics";
NSString *const kSettingKeyPreview = @"key_preview";
NSString *const kSettingLandscapeFold = @"fold_landscape";
NSString *const kSettingGamepad = @"gamepad_mode";
NSString *const kSettingGamepadMap = @"gamepad_map";
NSString *const kSettingMouseLock = @"mouse_lock";
NSString *const kSettingPinchZoom = @"pinch_zoom";
NSString *const kSettingScreenStyle = @"screen_style";
NSString *const kSettingVolumeMaster = @"volume_master";
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
	mpu98ii_midiclockout = [[NSUserDefaults standardUserDefaults] boolForKey:kSettingMidiClockOut] ? 1 : 0;
	synth_settingschanged();
	UINT8 master = (UINT8)MIN(MAX([[NSUserDefaults standardUserDefaults] integerForKey:kSettingVolumeMaster], 0), 100);
	if (master != np2cfg.vol_master) {
		np2cfg.vol_master = master;
		if (pccore.realclock) {		/* sound_init() applies them at start */
			settings_applyvolumes();
		}
	}

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

NSInteger settings_landscapefold(void)
{
	return [[NSUserDefaults standardUserDefaults] integerForKey:kSettingLandscapeFold];
}

NSArray<NSString *> *settings_landscapefolds(void)
{
	return @[ @"上に画面・下にキーボード", @"左に画面・右にキーボード", @"右に画面・左にキーボード" ];
}

NSInteger settings_gamepadmode(void)
{
	return [[NSUserDefaults standardUserDefaults] integerForKey:kSettingGamepad];
}

NSArray<NSString *> *settings_gamepadmodes(void)
{
	return @[ @"矢印キー", @"テンキー（8・2・4・6）", @"ジョイスティック端子" ];
}

BOOL settings_mouselock(void)
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingMouseLock];
}

BOOL settings_pinchzoom(void)
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingPinchZoom];
}

NSInteger settings_screenstyle(void)
{
	return [[NSUserDefaults standardUserDefaults] integerForKey:kSettingScreenStyle];
}

NSArray<NSString *> *settings_screenstyles(void)
{
	return @[ @"くっきり（ドット）", @"なめらか", @"ブラウン管風（走査線）" ];
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

NSString *settings_screenkeyboardshorttitle(NSString *identifier)
{
	NSDictionary<NSString *, NSString *> *titles = @{ @"pc98": @"PC-98", @"rcp": @"レコンポーザ", @"game": @"ゲーム", kScreenKeyboardSystem: @"iOS" };
	return titles[identifier] ?: settings_screenkeyboardtitle(identifier);
}

void settings_savenp2cfg(void)
{
	sysmng_update(SYS_UPDATECFG | SYS_UPDATEOSCFG);
}

/* As pccore.c's sound_init() sets them. */
void settings_applyvolumes(void)
{
	UINT master = np2cfg.vol_master;
	beep_setvol(np2cfg.BEEP_VOL);
	opngen_setvol(np2cfg.vol_fm * master / 100);
	psggen_setvol(np2cfg.vol_ssg * master / 100);
	rhythm_setvol(np2cfg.vol_rhythm * master / 100);
	adpcm_setvol(np2cfg.vol_adpcm * master / 100);
	pcm86gen_setvol(np2cfg.vol_pcm * master / 100);
	oplgen_setvol(np2cfg.vol_fm * master / 100);
}

void settings_initialize(void)
{

	/* Settings.bundle defaults are not visible to the app until the user
	 * opens the Settings app, so register them here as well. */
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{ kSettingMidiOutputLatency: @20, kSettingMidiInputLatency: @20, kSettingKeyboardLayout: @(KEYLAYOUT_JIS),
		kSettingRunInBackground: @YES, kSettingResume: @YES, kSettingShowSpeed: @YES,
		kSettingScreenKeyboard: @"pc98", kSettingScreenKeyboardShown: @YES, kSettingTrackpadSpeed: @100,
		kSettingKeyHaptics: @YES, kSettingKeyPreview: @YES, kSettingMouseLock: @YES, kSettingPinchZoom: @YES,
		kSettingVolumeMaster: @100 }];
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
