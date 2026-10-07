/**
 * @file	lifecycle.m
 * @brief	Background / foreground handling and resuming the last session
 *
 * iOS may terminate a backgrounded app at any time, so the machine state is
 * saved to np2.sav (NP2's resume file) whenever the app goes to the
 * background (and again when a running app is terminated), and loaded at the
 * next launch ("前回の状態から再開"). A state whose disk images changed
 * afterwards is not loaded.
 * NP2's own resume (np2oscfg.resume) only saves at a normal exit, which iOS
 * apps do not have.
 *
 * With "バックグラウンドでも動作" on (default), the emulator keeps running in
 * the background (UIBackgroundModes audio), e.g. so that a sequencer keeps
 * playing to external MIDI devices. Off, sound and MIDI are stopped so that
 * iOS suspends the app.
 */

#include "compiler.h"
#include "lifecycle.h"
#include "settings.h"

#import <UIKit/UIKit.h>
#include <mach/mach_time.h>
#include <cpucore.h>
#include <pccore.h>
#include <statsave.h>
#include <dosio.h>
#include <np2.h>
#include <soundmng.h>
#include <common/strres.h>

extern void cmmidi_allnotesoff(void);

static BOOL s_paused;

static const OEMCHAR *state_path(void)
{
	return file_getcd(OEMTEXT("np2.sav"));
}

static void show_alert(NSString *title, NSString *message)
{
	UIWindowScene *scene = nil;
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if ([s isKindOfClass:[UIWindowScene class]]) {
			scene = (UIWindowScene *)s;
		}
	}
	UIViewController *root = scene.windows.firstObject.rootViewController;
	while (root.presentedViewController) {
		root = root.presentedViewController;
	}
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[root presentViewController:alert animated:YES completion:nil];
}

static void restore_state(void)
{
	OEMCHAR path[MAX_PATH];
	OEMCHAR info[1024];

	file_cpyname(path, state_path(), NELEMENTS(path));
	if (!settings_resume() || ![[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:path]]) {
		return;
	}
	int ret = statsave_check(path, info, NELEMENTS(info));
	if (ret == STATFLAG_SUCCESS) {
		ret = statsave_load(path);
		NSLog(@"lifecycle: restored the last session (%d)", ret);
		return;
	}
	/* Saved by another build (STATFLAG_VERSION etc.) or the disks changed:
	 * loading could corrupt the disks, so start fresh. */
	NSLog(@"lifecycle: not restoring the last session (%d) %s", ret, info);
	file_delete(path);
	show_alert(@"前回の状態から再開できませんでした",
		(ret & STATFLAG_DISKCHG) ? @"ディスクイメージが前回から変わっています。通常どおり起動しました。"
		                         : @"保存された状態がこのバージョンと合いません。通常どおり起動しました。");
}

static void save_state(void)
{
	if (settings_resume()) {
		int ret = flagsave(str_sav);
		NSLog(@"lifecycle: saved state (%d)", ret);
	}
	else {
		flagdelete(str_sav);
	}
}

static void did_enter_background(void)
{
	save_state();
	if (!settings_runinbackground()) {
		cmmidi_allnotesoff();
		soundmng_stop();
		s_paused = YES;
		NSLog(@"lifecycle: paused");
	}
}

static void will_enter_foreground(void)
{
	if (s_paused) {
		soundmng_play();
		s_paused = NO;
		NSLog(@"lifecycle: resumed");
	}
}

void lifecycle_start(void)
{
	restore_state();
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
	            usingBlock:^(NSNotification *note) { (void)note; did_enter_background(); }];
	[nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil
	            usingBlock:^(NSNotification *note) { (void)note; will_enter_foreground(); }];
	/* An app running in the background is told before iOS terminates it;
	 * the state saved when it went to the background is out of date by then
	 * (the disks were written since, and that state would be refused). */
	[nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil
	            usingBlock:^(NSNotification *note) { (void)note; save_state(); }];
}

// ---- emulation speed

static double host_seconds(UINT64 host)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return (double)host * tb.numer / tb.denom / 1e9;
}

double lifecycle_emulationspeed(void)
{
	static UINT64 lasthost;
	static UINT32 lastclock;
	static double emulated;		/* seconds of emulated time in the window */
	static UINT64 windowstart;
	static double speed = -1;

	UINT64 now = mach_absolute_time();
	UINT32 clock = CPU_CLOCK + CPU_BASECLOCK - CPU_REMCLOCK;
	if (lasthost == 0 || pccore.realclock == 0 || host_seconds(now - lasthost) > 2.0) {
		/* first call or the app was suspended: start over */
		windowstart = now;
		emulated = 0;
		speed = -1;
	}
	else {
		emulated += (double)(UINT32)(clock - lastclock) / pccore.realclock;
	}
	lasthost = now;
	lastclock = clock;

	double elapsed = host_seconds(now - windowstart);
	if (elapsed >= 1.0) {
		speed = emulated / elapsed;
		windowstart = now;
		emulated = 0;
	}
	return speed;
}
