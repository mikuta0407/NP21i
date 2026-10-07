/**
 * @file	midiport.m
 * @brief	CoreMIDI endpoints used by the MIDI COMMNG (cmmidi.c)
 */

#include "compiler.h"
#include "midiport.h"

#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdatomic.h>

/* MIDISend / MIDIReceived / MIDIReadProc are deprecated in favour of the UMP
 * based API, but the emulator produces a MIDI 1.0 byte stream, which these
 * calls take as-is (including SysEx). */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define VIRTUAL_OUT_NAME	CFSTR("NP21 MIDI OUT")
#define VIRTUAL_IN_NAME		CFSTR("NP21 MIDI IN")

enum {
	MIDIIN_RINGSIZE		= 1 << 14,		/* power of two */
	MIDIIN_MAXSOURCES	= 32
};

struct _midiport_out {
	MIDIEndpointRef	dests[32];
	UINT			ndests;
};

typedef struct {
	UINT64	time;		/* host time the byte arrived */
	UINT8	data;
} MIDIINBYTE;

struct _midiport_in {
	MIDIEndpointRef	sources[MIDIIN_MAXSOURCES];
	UINT			nsources;
	/* single-producer (CoreMIDI thread) / single-consumer (emulator) ring */
	_Atomic UINT	head;
	_Atomic UINT	tail;
	MIDIINBYTE		ring[MIDIIN_RINGSIZE];
	UINT64			lastreadtime;
};

static MIDIClientRef s_client;
static MIDIPortRef s_outport;
static MIDIPortRef s_inport;
static MIDIEndpointRef s_virtualout;
static MIDIEndpointRef s_virtualin;
static os_unfair_lock s_inlock = OS_UNFAIR_LOCK_INIT;
static MIDIPORTIN s_activein;		/* receives data from s_virtualin */

static NSString *endpoint_name(MIDIEndpointRef ep)
{
	CFStringRef name = NULL;
	if (MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &name) != noErr || name == NULL) {
		return @"";
	}
	return (__bridge_transfer NSString *)name;
}

static BOOL selection_matches(const char *selection, MIDIEndpointRef ep)
{
	if (selection == NULL || selection[0] == '\0' || strcmp(selection, MIDIPORT_ALL) == 0) {
		return TRUE;
	}
	NSString *wanted = [NSString stringWithUTF8String:selection];
	return [endpoint_name(ep) rangeOfString:wanted options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL is_nc(const char *selection)
{
	return selection != NULL && milstr_cmp(selection, MIDIPORT_NC) == 0;
}

static void ring_push(MIDIPORTIN in, const UINT8 *data, UINT length, UINT64 time)
{
	UINT head = atomic_load_explicit(&in->head, memory_order_relaxed);
	UINT tail = atomic_load_explicit(&in->tail, memory_order_acquire);
	for (UINT i = 0; i < length; i++) {
		UINT next = (head + 1) & (MIDIIN_RINGSIZE - 1);
		if (next == tail) {
			break;	/* overflow: drop the rest */
		}
		in->ring[head].time = time;
		in->ring[head].data = data[i];
		head = next;
	}
	atomic_store_explicit(&in->head, head, memory_order_release);
}

static void read_proc(const MIDIPacketList *list, void *readProcRefCon, void *srcConnRefCon)
{
	(void)readProcRefCon;
	(void)srcConnRefCon;

	os_unfair_lock_lock(&s_inlock);
	MIDIPORTIN in = s_activein;
	if (in) {
		const MIDIPacket *packet = &list->packet[0];
		UINT64 now = mach_absolute_time();
		for (UInt32 i = 0; i < list->numPackets; i++) {
			/* Drivers stamp the arrival time; virtual sources may send 0 or a
			 * future time, which are treated as "now". */
			UINT64 time = (packet->timeStamp && packet->timeStamp <= now) ? packet->timeStamp : now;
			ring_push(in, packet->data, packet->length, time);
			packet = MIDIPacketNext(packet);
		}
	}
	os_unfair_lock_unlock(&s_inlock);
}

BOOL midiport_initialize(void)
{
	if (s_client) {
		return TRUE;
	}
	OSStatus err = MIDIClientCreateWithBlock(CFSTR("NP21"), &s_client, ^(const MIDINotification *message) {
		(void)message;
	});
	if (err != noErr) {
		NSLog(@"midiport: MIDIClientCreate failed (%d)", (int)err);
		s_client = 0;
		return FALSE;
	}
	MIDIOutputPortCreate(s_client, CFSTR("NP21 Out"), &s_outport);
	MIDIInputPortCreate(s_client, CFSTR("NP21 In"), read_proc, NULL, &s_inport);
	/* Virtual endpoints need UIBackgroundModes=audio in Info.plist; not fatal. */
	err = MIDISourceCreate(s_client, VIRTUAL_OUT_NAME, &s_virtualout);
	if (err != noErr) {
		NSLog(@"midiport: could not create virtual source (%d)", (int)err);
		s_virtualout = 0;
	}
	err = MIDIDestinationCreate(s_client, VIRTUAL_IN_NAME, read_proc, NULL, &s_virtualin);
	if (err != noErr) {
		NSLog(@"midiport: could not create virtual destination (%d)", (int)err);
		s_virtualin = 0;
	}
	NSLog(@"midiport: %lu destinations, %lu sources",
		(unsigned long)MIDIGetNumberOfDestinations(), (unsigned long)MIDIGetNumberOfSources());

	for (ItemCount i = 0; i < MIDIGetNumberOfDestinations(); i++) {
		NSLog(@"midiport: destination %lu: %@", (unsigned long)i, endpoint_name(MIDIGetDestination(i)));
	}
	for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
		NSLog(@"midiport: source %lu: %@", (unsigned long)i, endpoint_name(MIDIGetSource(i)));
	}
	return TRUE;
}

// ---- output

MIDIPORTOUT midiport_openout(const char *selection)
{
	if (is_nc(selection) || !midiport_initialize()) {
		return NULL;
	}
	MIDIPORTOUT out = calloc(1, sizeof(*out));
	if (out == NULL) {
		return NULL;
	}
	for (ItemCount i = 0; i < MIDIGetNumberOfDestinations() && out->ndests < NELEMENTS(out->dests); i++) {
		MIDIEndpointRef ep = MIDIGetDestination(i);
		if (ep == s_virtualin) {
			continue;	/* never loop back into ourselves */
		}
		if (selection_matches(selection, ep)) {
			out->dests[out->ndests++] = ep;
			NSLog(@"midiport: output -> %@", endpoint_name(ep));
		}
	}
	return out;
}

void midiport_send(MIDIPORTOUT out, const UINT8 *data, UINT length, UINT64 timestamp)
{
	if (out == NULL || length == 0) {
		return;
	}
	/* Large enough for the longest SysEx cmmidi.c buffers (1KB). */
	Byte storage[1024 + 128];
	MIDIPacketList *list = (MIDIPacketList *)storage;
	MIDIPacket *packet = MIDIPacketListInit(list);
	packet = MIDIPacketListAdd(list, sizeof(storage), packet, (MIDITimeStamp)timestamp, length, data);
	if (packet == NULL) {
		return;
	}
	for (UINT i = 0; i < out->ndests; i++) {
		MIDISend(s_outport, out->dests[i], list);
	}
	if (s_virtualout) {
		MIDIReceived(s_virtualout, list);
	}
}

void midiport_closeout(MIDIPORTOUT out)
{
	free(out);
}

// ---- input

MIDIPORTIN midiport_openin(const char *selection)
{
	if (is_nc(selection) || !midiport_initialize()) {
		return NULL;
	}
	MIDIPORTIN in = calloc(1, sizeof(*in));
	if (in == NULL) {
		return NULL;
	}
	for (ItemCount i = 0; i < MIDIGetNumberOfSources() && in->nsources < MIDIIN_MAXSOURCES; i++) {
		MIDIEndpointRef ep = MIDIGetSource(i);
		if (ep == s_virtualout) {
			continue;
		}
		if (selection_matches(selection, ep)) {
			MIDIPortConnectSource(s_inport, ep, NULL);
			in->sources[in->nsources++] = ep;
			NSLog(@"midiport: input <- %@", endpoint_name(ep));
		}
	}
	os_unfair_lock_lock(&s_inlock);
	s_activein = in;
	os_unfair_lock_unlock(&s_inlock);
	return in;
}

UINT midiport_read(MIDIPORTIN in, UINT8 *data, UINT64 until)
{
	if (in == NULL) {
		return 0;
	}
	UINT tail = atomic_load_explicit(&in->tail, memory_order_relaxed);
	UINT head = atomic_load_explicit(&in->head, memory_order_acquire);
	if (tail == head) {
		return 0;
	}
	if (until && in->ring[tail].time > until) {
		return 0;	/* not yet, in emulated time */
	}
	*data = in->ring[tail].data;
	in->lastreadtime = in->ring[tail].time;
	atomic_store_explicit(&in->tail, (tail + 1) & (MIDIIN_RINGSIZE - 1), memory_order_release);
	return 1;
}

UINT64 midiport_lastreadtime(MIDIPORTIN in)
{
	return in ? in->lastreadtime : 0;
}

void midiport_closein(MIDIPORTIN in)
{
	if (in == NULL) {
		return;
	}
	for (UINT i = 0; i < in->nsources; i++) {
		MIDIPortDisconnectSource(s_inport, in->sources[i]);
	}
	os_unfair_lock_lock(&s_inlock);
	if (s_activein == in) {
		s_activein = NULL;
	}
	os_unfair_lock_unlock(&s_inlock);
	free(in);
}
