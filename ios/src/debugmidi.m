/**
 * @file	debugmidi.m
 * @brief	MIDI loopback tools for testing on the simulator (debug builds only)
 *
 * The simulator has its own CoreMIDI server, isolated from the host Mac, so
 * the app's virtual endpoints are checked from inside the app:
 *
 * NP2_DEBUG_MIDIMON=1
 *   Connects a separate client to the virtual source "NP21 MIDI OUT" and logs
 *   every packet to Documents/sdlnp21kai/midimon.log as
 *   "<ms since start> <hex bytes>". The time is the packet's delivery
 *   timestamp (or the arrival time when the packet is not timestamped).
 *
 * NP2_DEBUG_MIDIIN="<delay ms>:<hex bytes>,..."
 *   Sends the given messages to the virtual destination "NP21 MIDI IN",
 *   e.g. "40000:90 3c 64,500:80 3c 00".
 *   While the app runs, a script written to debugmidiin.txt in the data
 *   directory is also sent (same format) and the file is deleted.
 */

#include "debugmidi.h"

#ifndef NDEBUG

#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static MIDIClientRef s_client;
static FILE *s_monlog;
static uint64_t s_start;

static double host_to_ms(uint64_t host)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return ((double)host - (double)s_start) * tb.numer / tb.denom / 1e6;
}

static double elapsed_ms(void)
{
	return host_to_ms(mach_absolute_time());
}

static MIDIEndpointRef find_endpoint(BOOL source, NSString *name)
{
	ItemCount n = source ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations();
	for (ItemCount i = 0; i < n; i++) {
		MIDIEndpointRef ep = source ? MIDIGetSource(i) : MIDIGetDestination(i);
		CFStringRef cf = NULL;
		if (MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf) == noErr && cf) {
			BOOL match = [(__bridge_transfer NSString *)cf isEqualToString:name];
			if (match) {
				return ep;
			}
		}
	}
	return 0;
}

static void monitor_proc(const MIDIPacketList *list, void *ref, void *src)
{
	(void)ref;
	(void)src;
	const MIDIPacket *packet = &list->packet[0];
	for (UInt32 i = 0; i < list->numPackets; i++) {
		fprintf(s_monlog, "%.1f", packet->timeStamp ? host_to_ms(packet->timeStamp) : elapsed_ms());
		for (UInt16 j = 0; j < packet->length; j++) {
			fprintf(s_monlog, " %02x", packet->data[j]);
		}
		fputc('\n', s_monlog);
		packet = MIDIPacketNext(packet);
	}
	fflush(s_monlog);
}

static void start_monitor(void)
{
	MIDIEndpointRef src = find_endpoint(TRUE, @"NP21 MIDI OUT");
	if (!src) {
		NSLog(@"debugmidi: NP21 MIDI OUT not found");
		return;
	}
	s_monlog = fopen("midimon.log", "w");	/* cwd is the data directory */
	if (!s_monlog) {
		return;
	}
	MIDIPortRef port;
	MIDIInputPortCreate(s_client, CFSTR("monitor"), monitor_proc, NULL, &port);
	MIDIPortConnectSource(port, src, NULL);
	NSLog(@"debugmidi: monitoring NP21 MIDI OUT -> midimon.log");
}

static void send_script(char *script, MIDIPortRef port, MIDIEndpointRef dst)
{
	char *saveptr = NULL;

	for (char *step = strtok_r(script, ",", &saveptr); step; step = strtok_r(NULL, ",", &saveptr)) {
		char *colon = strchr(step, ':');
		if (!colon || !dst) {
			continue;
		}
		*colon = '\0';
		usleep((useconds_t)atoi(step) * 1000);

		Byte bytes[256];
		UInt16 count = 0;
		for (char *p = colon + 1; *p && count < sizeof(bytes);) {
			char *end;
			long v = strtol(p, &end, 16);
			if (end == p) {
				break;
			}
			bytes[count++] = (Byte)v;
			p = end;
		}
		Byte storage[512];
		MIDIPacketList *list = (MIDIPacketList *)storage;
		MIDIPacket *packet = MIDIPacketListInit(list);
		MIDIPacketListAdd(list, sizeof(storage), packet, 0, count, bytes);
		MIDISend(port, dst, list);
		if (s_monlog) {
			fprintf(s_monlog, "%.1f IN", elapsed_ms());
			for (UInt16 j = 0; j < count; j++) {
				fprintf(s_monlog, " %02x", bytes[j]);
			}
			fputc('\n', s_monlog);
			fflush(s_monlog);
		}
	}
}

static void *midiin_thread(void *arg)
{
	char *script = arg;
	MIDIEndpointRef dst = find_endpoint(FALSE, @"NP21 MIDI IN");
	MIDIPortRef port;
	MIDIOutputPortCreate(s_client, CFSTR("feeder"), &port);

	if (script) {
		send_script(script, port, dst);
		free(script);
	}
	/* cwd is the data directory (see main.m) */
	for (;;) {
		usleep(300 * 1000);
		FILE *fp = fopen("debugmidiin.txt", "r");
		if (!fp) {
			continue;
		}
		char buf[4096];
		size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
		fclose(fp);
		remove("debugmidiin.txt");
		buf[n] = '\0';
		buf[strcspn(buf, "\r\n")] = '\0';
		send_script(buf, port, dst);
	}
	return NULL;
}

void debugmidi_start(void)
{
	const char *mon = getenv("NP2_DEBUG_MIDIMON");
	const char *in = getenv("NP2_DEBUG_MIDIIN");
	s_start = mach_absolute_time();
	if (MIDIClientCreate(CFSTR("NP21 debug"), NULL, NULL, &s_client) != noErr) {
		return;
	}
	if (mon && mon[0]) {
		start_monitor();
	}
	pthread_t th;
	if (pthread_create(&th, NULL, midiin_thread, (in && in[0]) ? strdup(in) : NULL) == 0) {
		pthread_detach(th);
	}
}

#else

void debugmidi_start(void)
{
}

#endif
