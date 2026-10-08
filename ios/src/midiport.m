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

/* The app's virtual endpoints, one pair per MIDI port of the emulated board
 * (the B pair only for S-MPU port B, created when it is opened). */
static const CFStringRef s_virtualoutnames[MIDIPORT_VIRTUALS] = {
	CFSTR("NP21 MIDI OUT"), CFSTR("NP21 MIDI OUT B")
};
static const CFStringRef s_virtualinnames[MIDIPORT_VIRTUALS] = {
	CFSTR("NP21 MIDI IN"), CFSTR("NP21 MIDI IN B")
};

enum {
	MIDIIN_RINGSIZE		= 1 << 14,		/* power of two */
	MIDIIN_MAXSOURCES	= 32
};

struct _midiport_out {
	const char		*selection;		/* live: points into the config */
	UINT			virtual;		/* which "NP21 MIDI OUT" also gets the data */
	MIDIEndpointRef	dests[32];
	UINT			ndests;
	MIDIPORTOUT		next;
};

typedef struct {
	UINT64	time;		/* host time the byte arrived */
	UINT8	data;
} MIDIINBYTE;

struct _midiport_in {
	const char		*selection;		/* live: points into the config */
	UINT			virtual;		/* which "NP21 MIDI IN" it also receives */
	MIDIPortRef		port;			/* its own, so that each input gets every source */
	MIDIPORTIN		next;
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
static MIDIEndpointRef s_virtualout[MIDIPORT_VIRTUALS];
static MIDIEndpointRef s_virtualin[MIDIPORT_VIRTUALS];
static os_unfair_lock s_inlock = OS_UNFAIR_LOCK_INIT;	/* guards s_ins for the CoreMIDI thread */
static MIDIPORTOUT s_outs;			/* open handles, re-resolved on changes */
static MIDIPORTIN s_ins;

void (*midiport_onchange)(void);

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

static BOOL is_virtual(MIDIEndpointRef ep)
{
	for (UINT i = 0; i < MIDIPORT_VIRTUALS; i++) {
		if (ep && (ep == s_virtualout[i] || ep == s_virtualin[i])) {
			return TRUE;
		}
	}
	return FALSE;
}

static BOOL is_nc(const char *selection)
{
	return selection != NULL && (milstr_cmp(selection, MIDIPORT_NC) == 0 || milstr_cmp(selection, MIDIPORT_SYNTH) == 0);
}

static void resolve_out(MIDIPORTOUT out)
{
	out->ndests = 0;
	if (is_nc(out->selection)) {
		return;
	}
	for (ItemCount i = 0; i < MIDIGetNumberOfDestinations() && out->ndests < NELEMENTS(out->dests); i++) {
		MIDIEndpointRef ep = MIDIGetDestination(i);
		if (is_virtual(ep)) {
			continue;	/* never loop back into ourselves */
		}
		if (selection_matches(out->selection, ep)) {
			out->dests[out->ndests++] = ep;
			NSLog(@"midiport: output -> %@", endpoint_name(ep));
		}
	}
}

static void resolve_in(MIDIPORTIN in)
{
	for (UINT i = 0; i < in->nsources; i++) {
		MIDIPortDisconnectSource(in->port, in->sources[i]);
	}
	in->nsources = 0;
	if (is_nc(in->selection)) {
		return;
	}
	for (ItemCount i = 0; i < MIDIGetNumberOfSources() && in->nsources < MIDIIN_MAXSOURCES; i++) {
		MIDIEndpointRef ep = MIDIGetSource(i);
		if (is_virtual(ep)) {
			continue;
		}
		if (selection_matches(in->selection, ep)) {
			MIDIPortConnectSource(in->port, ep, NULL);
			in->sources[in->nsources++] = ep;
			NSLog(@"midiport: input <- %@", endpoint_name(ep));
		}
	}
}

void midiport_refresh(void)
{
	for (MIDIPORTOUT out = s_outs; out; out = out->next) {
		resolve_out(out);
	}
	for (MIDIPORTIN in = s_ins; in; in = in->next) {
		resolve_in(in);
	}
}

void midiport_list(BOOL sources, void (^callback)(const char *name))
{
	if (!midiport_initialize()) {
		return;
	}
	ItemCount n = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations();
	for (ItemCount i = 0; i < n; i++) {
		MIDIEndpointRef ep = sources ? MIDIGetSource(i) : MIDIGetDestination(i);
		if (is_virtual(ep)) {
			continue;
		}
		callback(endpoint_name(ep).UTF8String);
	}
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

static void push_packets(MIDIPORTIN in, const MIDIPacketList *list)
{
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

/* From the hardware / network sources of one input (refCon: the handle). */
static void read_proc(const MIDIPacketList *list, void *readProcRefCon, void *srcConnRefCon)
{
	(void)srcConnRefCon;

	os_unfair_lock_lock(&s_inlock);
	for (MIDIPORTIN in = s_ins; in; in = in->next) {
		if (in == readProcRefCon) {		/* still open */
			push_packets(in, list);
			break;
		}
	}
	os_unfair_lock_unlock(&s_inlock);
}

/* From other apps, to "NP21 MIDI IN" (refCon: its index): every input of that port gets it. */
static void virtual_read_proc(const MIDIPacketList *list, void *readProcRefCon, void *srcConnRefCon)
{
	(void)srcConnRefCon;

	os_unfair_lock_lock(&s_inlock);
	for (MIDIPORTIN in = s_ins; in; in = in->next) {
		if (in->virtual == (UINT)(uintptr_t)readProcRefCon) {
			push_packets(in, list);
		}
	}
	os_unfair_lock_unlock(&s_inlock);
}

/* The app's virtual endpoints of port `index`. Need UIBackgroundModes=audio in Info.plist; not fatal. */
static void create_virtuals(UINT index)
{
	if (s_virtualout[index] == 0 &&
	    MIDISourceCreate(s_client, s_virtualoutnames[index], &s_virtualout[index]) != noErr) {
		NSLog(@"midiport: could not create virtual source %@", s_virtualoutnames[index]);
		s_virtualout[index] = 0;
	}
	if (s_virtualin[index] == 0 &&
	    MIDIDestinationCreate(s_client, s_virtualinnames[index], virtual_read_proc,
	                          (void *)(uintptr_t)index, &s_virtualin[index]) != noErr) {
		NSLog(@"midiport: could not create virtual destination %@", s_virtualinnames[index]);
		s_virtualin[index] = 0;
	}
}

BOOL midiport_initialize(void)
{
	if (s_client) {
		return TRUE;
	}
	OSStatus err = MIDIClientCreateWithBlock(CFSTR("NP21"), &s_client, ^(const MIDINotification *message) {
		/* Devices come and go (USB, Bluetooth): re-resolve the selections.
		 * Handles are used by the emulator on the main thread. */
		if (message->messageID == kMIDIMsgSetupChanged) {
			dispatch_async(dispatch_get_main_queue(), ^{
				midiport_refresh();
				if (midiport_onchange) {
					midiport_onchange();
				}
			});
		}
	});
	if (err != noErr) {
		NSLog(@"midiport: MIDIClientCreate failed (%d)", (int)err);
		s_client = 0;
		return FALSE;
	}
	MIDIOutputPortCreate(s_client, CFSTR("NP21 Out"), &s_outport);
	create_virtuals(0);
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

MIDIPORTOUT midiport_openout(const char *selection, UINT virtual)
{
	if (!midiport_initialize() || virtual >= MIDIPORT_VIRTUALS) {
		return NULL;
	}
	MIDIPORTOUT out = calloc(1, sizeof(*out));
	if (out == NULL) {
		return NULL;
	}
	create_virtuals(virtual);
	out->selection = selection;
	out->virtual = virtual;
	resolve_out(out);
	out->next = s_outs;
	s_outs = out;
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
	if (s_virtualout[out->virtual]) {
		MIDIReceived(s_virtualout[out->virtual], list);
	}
}

void midiport_closeout(MIDIPORTOUT out)
{
	for (MIDIPORTOUT *p = &s_outs; *p; p = &(*p)->next) {
		if (*p == out) {
			*p = out->next;
			break;
		}
	}
	free(out);
}

// ---- input

MIDIPORTIN midiport_openin(const char *selection, UINT virtual)
{
	if (!midiport_initialize() || virtual >= MIDIPORT_VIRTUALS) {
		return NULL;
	}
	MIDIPORTIN in = calloc(1, sizeof(*in));
	if (in == NULL) {
		return NULL;
	}
	create_virtuals(virtual);
	in->selection = selection;
	in->virtual = virtual;
	if (MIDIInputPortCreate(s_client, CFSTR("NP21 In"), read_proc, in, &in->port) != noErr) {
		free(in);
		return NULL;
	}
	resolve_in(in);
	os_unfair_lock_lock(&s_inlock);
	in->next = s_ins;
	s_ins = in;
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
	os_unfair_lock_lock(&s_inlock);
	for (MIDIPORTIN *p = &s_ins; *p; p = &(*p)->next) {
		if (*p == in) {
			*p = in->next;
			break;
		}
	}
	os_unfair_lock_unlock(&s_inlock);
	MIDIPortDispose(in->port);
	free(in);
}

void midiport_debugdump(void)
{
	for (MIDIPORTIN in = s_ins; in; in = in->next) {
		UINT pending = (atomic_load(&in->head) - atomic_load(&in->tail)) & (MIDIIN_RINGSIZE - 1);
		NSLog(@"midiport: input %s (virtual %u): %u sources, %u bytes waiting",
		      in->selection ? in->selection : "", in->virtual, in->nsources, pending);
	}
}
