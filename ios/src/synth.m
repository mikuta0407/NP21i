/**
 * @file	synth.m
 * @brief	The built-in MIDI sound generator (a SoundFont / DLS bank played by
 *			Apple's MIDISynth), mixed into the PC-98's sound
 *
 * The MIDISynth audio unit is not connected to any output: sound.c pulls
 * its samples (sound_iosstream) whenever it prepares a block of the
 * PC-98's sound, up to the current point of emulated time; cmmidi.c calls
 * sound_sync() before each message, so a message applies from the sample
 * where the program sent it.
 */

#include "compiler.h"
#include "synth.h"
#include "midiport.h"

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <sound/sound.h>

const char cmmidi_synth[] = MIDIPORT_SYNTH;

NSString *const kSettingSynthBank = @"synth_bank";
NSString *const kSettingSynthVolume = @"synth_volume";

enum {
	MAX_FRAMES	= 4096
};

static AudioUnit s_unit;
static UINT s_rate;				/* of s_unit, as NP2's sound */
static NSString *s_loaded;		/* bank path in s_unit */
static Float64 s_sampletime;
static int s_users;
static float s_gain;
static float s_left[MAX_FRAMES];
static float s_right[MAX_FRAMES];

NSString *synth_bankdir(void)
{
	return @"soundfont";
}

BOOL synth_isbank(NSString *name)
{
	NSString *ext = name.pathExtension.lowercaseString;
	return [ext isEqualToString:@"sf2"] || [ext isEqualToString:@"dls"];
}

NSArray<NSString *> *synth_banks(void)
{
	NSMutableArray<NSString *> *banks = [NSMutableArray array];
	for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:synth_bankdir() error:nil]) {
		if (synth_isbank(name)) {
			[banks addObject:name];
		}
	}
	[banks sortUsingSelector:@selector(localizedStandardCompare:)];
	return banks;
}

NSString *synth_bank(void)
{
	NSArray<NSString *> *banks = synth_banks();
	NSString *chosen = [[NSUserDefaults standardUserDefaults] stringForKey:kSettingSynthBank];
	if (chosen && [banks containsObject:chosen]) {
		return chosen;
	}
	return banks.firstObject;
}

static void destroy_unit(void)
{
	if (s_unit) {
		AudioUnitUninitialize(s_unit);
		AudioComponentInstanceDispose(s_unit);
		s_unit = NULL;
	}
	s_loaded = nil;
}

static BOOL create_unit(UINT rate)
{
	AudioComponentDescription desc = {
		.componentType = kAudioUnitType_MusicDevice,
		.componentSubType = kAudioUnitSubType_MIDISynth,
		.componentManufacturer = kAudioUnitManufacturer_Apple,
	};
	AudioComponent component = AudioComponentFindNext(NULL, &desc);
	if (component == NULL || AudioComponentInstanceNew(component, &s_unit) != noErr) {
		NSLog(@"synth: no MIDISynth");
		s_unit = NULL;
		return NO;
	}
	AudioStreamBasicDescription format = {
		.mSampleRate = rate,
		.mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
		.mBytesPerPacket = sizeof(float),
		.mFramesPerPacket = 1,
		.mBytesPerFrame = sizeof(float),
		.mChannelsPerFrame = 2,
		.mBitsPerChannel = 32,
	};
	UInt32 frames = MAX_FRAMES;
	OSStatus err = AudioUnitSetProperty(s_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof(format));
	err = err ?: AudioUnitSetProperty(s_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, sizeof(frames));
	if (err != noErr) {
		NSLog(@"synth: could not set up (%d)", (int)err);
		destroy_unit();
		return NO;
	}
	s_rate = rate;
	return YES;
}

static NSString *bank_path(void)
{
	NSString *bank = synth_bank();
	return bank ? [synth_bankdir() stringByAppendingPathComponent:bank] : @"";
}

/* A new unit with the bank (when there is one: without, MIDISynth plays
 * nothing), ready to play. */
static void start_unit(UINT rate)
{
	destroy_unit();		/* the bank can only be set before it is initialized */
	if (rate == 0 || !create_unit(rate)) {
		return;
	}
	NSString *path = bank_path();
	if (path.length) {
		NSURL *url = [NSURL fileURLWithPath:[[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:path]];
		CFURLRef cfurl = (__bridge CFURLRef)url;
		OSStatus err = AudioUnitSetProperty(s_unit, kMusicDeviceProperty_SoundBankURL, kAudioUnitScope_Global, 0, &cfurl, sizeof(cfurl));
		NSLog(@"synth: bank %@ (%d)", path, (int)err);
	}
	OSStatus err = AudioUnitInitialize(s_unit);
	if (err != noErr) {
		NSLog(@"synth: could not start (%d)", (int)err);
		destroy_unit();
		return;
	}
	s_loaded = path;
	s_sampletime = 0;
}

static void apply_volume(void)
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSInteger volume = [defaults objectForKey:kSettingSynthVolume] ? [defaults integerForKey:kSettingSynthVolume] : 100;
	/* full scale is 32767 in NP2's mix; the bank's loudest notes are near it */
	s_gain = 32767.0f * 0.8f * (float)MAX(0, MIN(128, volume)) / 100.0f;
}

static void SOUNDCALL render(SINT32 *pcm, UINT count)
{
	if (s_users == 0) {
		return;
	}
	if (s_unit == NULL || s_rate != soundcfg.rate) {
		start_unit(soundcfg.rate);
		if (s_unit == NULL) {
			return;
		}
	}
	while (count) {
		UInt32 frames = MIN(count, (UINT)MAX_FRAMES);
		struct {
			AudioBufferList list;
			AudioBuffer second;
		} buffers;
		buffers.list.mNumberBuffers = 2;
		buffers.list.mBuffers[0] = (AudioBuffer){1, frames * sizeof(float), s_left};
		buffers.list.mBuffers[1] = (AudioBuffer){1, frames * sizeof(float), s_right};
		AudioTimeStamp stamp = {.mSampleTime = s_sampletime, .mFlags = kAudioTimeStampSampleTimeValid};
		AudioUnitRenderActionFlags flags = 0;
		OSStatus err = AudioUnitRender(s_unit, &flags, &stamp, 0, frames, &buffers.list);
		if (err != noErr) {
			return;
		}
		s_sampletime += frames;
		for (UInt32 i = 0; i < frames; i++) {
			pcm[0] += (SINT32)(s_left[i] * s_gain);
			pcm[1] += (SINT32)(s_right[i] * s_gain);
			pcm += 2;
		}
		count -= frames;
	}
}

void synth_open(void)
{
	if (s_users++ == 0) {
		apply_volume();
		if (s_unit == NULL || s_rate != soundcfg.rate) {
			start_unit(soundcfg.rate);
		}
		sound_iosstream = render;
	}
}

void synth_close(void)
{
	if (s_users > 0 && --s_users == 0) {
		synth_allnotesoff();
		sound_iosstream = NULL;
	}
}

void synth_shortmsg(const UINT8 *msg, UINT length)
{
	if (s_unit == NULL || length == 0) {
		return;
	}
	MusicDeviceMIDIEvent(s_unit, msg[0], (length > 1) ? msg[1] : 0, (length > 2) ? msg[2] : 0, 0);
}

void synth_sysex(const UINT8 *data, UINT length)
{
	if (s_unit && length) {
		MusicDeviceSysEx(s_unit, data, length);
	}
}

void synth_allnotesoff(void)
{
	if (s_unit == NULL) {
		return;
	}
	for (UInt32 ch = 0; ch < 16; ch++) {
		MusicDeviceMIDIEvent(s_unit, 0xb0 | ch, 0x40, 0, 0);	/* sustain off */
		MusicDeviceMIDIEvent(s_unit, 0xb0 | ch, 0x78, 0, 0);	/* all sound off */
		MusicDeviceMIDIEvent(s_unit, 0xb0 | ch, 0x7b, 0, 0);	/* all notes off */
	}
}

void synth_settingschanged(void)
{
	apply_volume();
	if (s_unit && ![bank_path() isEqualToString:s_loaded]) {
		start_unit(s_rate);
	}
}
