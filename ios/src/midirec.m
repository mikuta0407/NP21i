/**
 * @file	midirec.m
 * @brief	Records the MIDI sent out to a Standard MIDI File
 *
 * Messages are kept as they come (host time, length, bytes) on the
 * emulator's thread, the main one, and turned into a track when stopped.
 * The times are those CoreMIDI sends at (cmmidi.c maps emulated time onto
 * host time), so the file plays as the device heard it.
 */

#include "midirec.h"

#include <mach/mach_time.h>

static BOOL s_recording;
static NSMutableData *s_events;		/* UINT64 time, UINT32 length, bytes */
static UINT64 s_first;

static double host2ms(UINT64 t)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return (double)t * tb.numer / tb.denom / 1e6;
}

void midirec_event(const UINT8 *buf, UINT leng, UINT64 hosttime)
{
	if (!s_recording || leng == 0 || buf[0] < 0x80 || (buf[0] >= 0xf8)) {
		return;		/* running status is not used by cmmidi; real time messages are left out */
	}
	if (s_events.length == 0) {
		s_first = hosttime;
	}
	UINT32 length = (UINT32)leng;
	[s_events appendBytes:&hosttime length:sizeof(hosttime)];
	[s_events appendBytes:&length length:sizeof(length)];
	[s_events appendBytes:buf length:leng];
}

BOOL midirec_isrecording(void)
{
	return s_recording;
}

void midirec_start(void)
{
	s_events = [NSMutableData data];
	s_recording = YES;
	NSLog(@"midirec: recording");
}

NSTimeInterval midirec_duration(void)
{
	if (!s_recording || s_events.length == 0) {
		return 0;
	}
	return (host2ms(mach_absolute_time()) - host2ms(s_first)) / 1000;
}

static void put_vlq(NSMutableData *data, UINT32 value)
{
	UINT8 bytes[5];
	int n = 0;
	bytes[n++] = value & 0x7f;
	while ((value >>= 7) != 0) {
		bytes[n++] = (UINT8)(0x80 | (value & 0x7f));
	}
	while (n > 0) {
		[data appendBytes:&bytes[--n] length:1];
	}
}

static void put_be(NSMutableData *data, UINT32 value, int bytes)
{
	for (int i = bytes - 1; i >= 0; i--) {
		UINT8 b = (UINT8)(value >> (i * 8));
		[data appendBytes:&b length:1];
	}
}

/* 480 ticks a beat, 500000 us a beat: 0.96 ticks a millisecond. */
static NSData *make_smf(NSData *events)
{
	NSMutableData *track = [NSMutableData data];
	static const UINT8 tempo[] = { 0x00, 0xff, 0x51, 0x03, 0x07, 0xa1, 0x20 };
	[track appendBytes:tempo length:sizeof(tempo)];
	const UINT8 *p = events.bytes;
	const UINT8 *end = p + events.length;
	UINT32 lastTick = 0;
	double base = host2ms(s_first);
	while (p + sizeof(UINT64) + sizeof(UINT32) <= end) {
		UINT64 time;
		UINT32 length;
		memcpy(&time, p, sizeof(time));
		memcpy(&length, p + sizeof(time), sizeof(length));
		p += sizeof(time) + sizeof(length);
		if (p + length > end) {
			break;
		}
		double ms = MAX(host2ms(time) - base, 0);
		UINT32 tick = MAX((UINT32)(ms * 0.96 + 0.5), lastTick);
		put_vlq(track, tick - lastTick);
		lastTick = tick;
		if (p[0] == 0xf0) {
			/* F0, length, the rest (with F7) */
			[track appendBytes:p length:1];
			put_vlq(track, length - 1);
			[track appendBytes:p + 1 length:length - 1];
		}
		else {
			[track appendBytes:p length:length];
		}
		p += length;
	}
	static const UINT8 eot[] = { 0x00, 0xff, 0x2f, 0x00 };
	[track appendBytes:eot length:sizeof(eot)];

	NSMutableData *smf = [NSMutableData data];
	[smf appendBytes:"MThd" length:4];
	put_be(smf, 6, 4);
	put_be(smf, 0, 2);		/* format 0 */
	put_be(smf, 1, 2);		/* one track */
	put_be(smf, 480, 2);
	[smf appendBytes:"MTrk" length:4];
	put_be(smf, (UINT32)track.length, 4);
	[smf appendData:track];
	return smf;
}

void midirec_stop(UIViewController *host)
{
	if (!s_recording) {
		return;
	}
	s_recording = NO;
	NSData *events = s_events;
	s_events = nil;
	if (events.length == 0) {
		NSLog(@"midirec: nothing recorded");
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MIDI は記録されませんでした"
		                                                               message:@"記録中に MIDI が送られませんでした。MIDI の出力先が「接続しない」になっていないか確認してください。"
		                                                        preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[host presentViewController:alert animated:YES completion:nil];
		return;
	}
	NSString *dir = [[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:@"midi"];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	NSDateFormatter *format = [NSDateFormatter new];
	format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
	format.dateFormat = @"yyyyMMdd-HHmmss";
	NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"NP21 %@.mid", [format stringFromDate:[NSDate date]]]];
	if (![make_smf(events) writeToFile:path atomically:YES]) {
		NSLog(@"midirec: could not write %@", path);
		return;
	}
	NSLog(@"midirec: saved %@ (%lu bytes of events)", path.lastPathComponent, (unsigned long)events.length);
	if (host) {
		UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:path] ]
		                                                                    applicationActivities:nil];
		UIPopoverPresentationController *popover = sheet.popoverPresentationController;
		if (popover) {
			popover.sourceView = host.view;
			popover.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
			popover.permittedArrowDirections = 0;
		}
		[host presentViewController:sheet animated:YES completion:nil];
	}
}
