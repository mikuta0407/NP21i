/**
 * @file	cmmidi.c
 * @brief	MIDI COMMNG for iOS (CoreMIDI / VERMOUTH)
 *
 * Derived from NP2kai sdl/cmmidi.c. The MIDI stream parser and the channel
 * state handling are kept as they are; the device I/O goes through midiport.m
 * (CoreMIDI) instead of /dev files, and MIDI-IN is actually received.
 *
 * Output timing: the emulator runs a whole frame of CPU time in a burst and
 * then sleeps, so sending each message "now" would bunch them up per frame.
 * Instead every message is stamped with its position in emulated time
 * (CPU clock) mapped onto host time, plus a fixed latency
 * (cmmidi_latency_ms), and CoreMIDI delivers it at that time.
 *
 * Input timing: received bytes keep their host arrival time and are handed to
 * the MPU only when emulated time reaches that moment (see midiin_until), so
 * that real-time recording follows the player's timing instead of the frame
 * rate. Together with the MPU polling on every tick (patch 0002) this places
 * notes within an MPU tick of when they were played.
 */

#include "compiler.h"

#include "np2.h"
#include "commng.h"
#include "cmmidi.h"
#include "midiport.h"
#include "midirec.h"
#include <common/mimpidef.h>
#include <sound/sound.h>

#include <cpucore.h>
#include <pccore.h>
#include <pccore.h>
#include <nevent.h>
#include <cbus/mpu98ii.h>
#include <mach/mach_time.h>

#include "sound/vermouth/vermouth.h"

#if defined(VERMOUTH_LIB)
extern MIDIMOD vermouth_module;

const char cmmidi_vermouth[] = "VERMOUTH";
#endif

/* Output latency for timestamped delivery. 0 sends immediately.
 * Set from the Settings app (settings.m). */
UINT cmmidi_latency_ms = 20;

/* Input latency for delivering MIDI-IN in emulated time (see midiin_until);
 * at least one frame (17.7ms) so that bytes arriving while the emulator
 * sleeps between frames can still be placed at the right point.
 * 0 delivers bytes as soon as the MPU polls. Set from the Settings app. */
UINT cmmidi_midiin_latency_ms = 20;

const char cmmidi_midiout_device[] = "MIDI-OUT device";
const char cmmidi_midiin_device[] = "MIDI-IN device";

#define MIDIOUTS(a, b, c)	(((c) << 16) + (b << 8) + (a))
#define MIDIOUTS2(a)		((a)[0] + ((a)[1] << 8))
#define MIDIOUTS3(a)		((a)[0] + ((a)[1] << 8) + ((a)[2] << 16))

const char *cmmidi_mdlname[] = {
	"MT-32",	"CM-32L",	"CM-64",
	"CM-300",	"CM-500(LA)",	"CM-500(GS)",
	"SC-55",	"SC-88",	"LA",
	"GM",		"GS",		"XG"
};

static const UINT8 EXCV_MTRESET[] = {
	0xfe, 0xfe, 0xfe
};
static const UINT8 EXCV_GMRESET[] = {
	0xf0, 0x7e, 0x7f, 0x09, 0x01, 0xf7
};
static const UINT8 EXCV_GSRESET[] = {
	0xf0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7f, 0x00, 0x41, 0xf7
};
static const UINT8 EXCV_XGRESET[] = {
	0xf0, 0x43, 0x10, 0x4c, 0x00, 0x00, 0x7e, 0x00, 0xf7
};

enum {
	MIDI_EXCLUSIVE		= 0xf0,
	MIDI_TIMECODE		= 0xf1,
	MIDI_SONGPOS		= 0xf2,
	MIDI_SONGSELECT		= 0xf3,
	MIDI_TUNEREQUEST	= 0xf6,
	MIDI_EOX		= 0xf7,
	MIDI_TIMING		= 0xf8,
	MIDI_START		= 0xfa,
	MIDI_CONTINUE		= 0xfb,
	MIDI_STOP		= 0xfc,
	MIDI_ACTIVESENSE	= 0xfe,
	MIDI_SYSTEMRESET	= 0xff
};

enum {
	MIDI_BUFFER		= (1 << 10),

	CMMIDI_MIDIOUT		= 0x01,
	CMMIDI_MIDIIN		= 0x02,
	CMMIDI_VERMOUTH		= 0x08,

	MIDICTRL_READY		= 0,
	MIDICTRL_2BYTES,
	MIDICTRL_3BYTES,
	MIDICTRL_EXCLUSIVE,
	MIDICTRL_TIMECODE,
	MIDICTRL_SYSTEM
};

struct _cmmidi;
typedef struct _cmmidi	_CMMIDI;
typedef struct _cmmidi	*CMMIDI;

typedef struct {
	UINT8	prog;
	UINT8	press;
	UINT16	bend;
	UINT8	ctrl[28];
} _MIDICH, *MIDICH;

struct _cmmidi {
	int		opened;
	void		(*outfn)(CMMIDI self, UINT32 msg, UINT cnt);
	MIDIPORTIN	hmidiin;
	MIDIPORTOUT	hmidiout;
	MIDIHDL		vermouth;

	/* emulated time -> host time mapping for output timestamps */
	UINT32		lastclock;
	UINT64		lasthost;

	/* emulated time (in host time units) and its offset from real time,
	 * for delivering MIDI-IN */
	UINT32		inclock;
	UINT64		inemu;
	SINT64		inoffset;

	UINT		midictrl;
	UINT		midisyscnt;
	UINT		mpos;

	UINT8		midilast;
	UINT8		midimodule;

	UINT8		buffer[MIDI_BUFFER];
	_MIDICH		mch[16];

	UINT8		def_en;
	MIMPIDEF	def;
};

static const UINT8 midictrltbl[] = {
	0, 1, 5, 7, 10, 11, 64,
	65, 66, 67, 84, 91, 93,
	94,			// for SC-88
	71, 72, 73, 74		// for XG
};

static UINT8 midictrlindex[128];

/* open instances, for cmmidi_allnotesoff() */
static CMMIDI s_instances[8];


// ----

static UINT64
ms2host(UINT ms)
{
	static mach_timebase_info_data_t tb;

	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return (UINT64)ms * 1000000 * tb.denom / tb.numer;
}

/* Host time at which the message being written now should be delivered. */
static UINT64
midi_timestamp(CMMIDI midi)
{
	UINT64 now, latency, target;
	UINT32 clock, elapsed;

	if (cmmidi_latency_ms == 0 || pccore.realclock == 0) {
		return 0;
	}
	now = mach_absolute_time();
	latency = ms2host(cmmidi_latency_ms);
	clock = CPU_CLOCK + CPU_BASECLOCK - CPU_REMCLOCK;
	elapsed = clock - midi->lastclock;	/* wraps safely within ~19s */

	if (midi->lasthost == 0 || elapsed >= pccore.realclock) {
		/* first message, or idle for more than a second */
		target = now + latency;
	}
	else {
		target = midi->lasthost + ms2host(1) * elapsed / (pccore.realclock / 1000);
		if (target < now) {
			/* emulation is slower than real time: frames run back to back,
			 * so sending immediately is already evenly spaced */
			target = now;
		}
		else if (target > now + latency * 2) {
			/* ran ahead of real time (e.g. after a pause): resync */
			target = now + latency;
		}
	}
	midi->lastclock = clock;
	midi->lasthost = target;
	return target;
}

/* Latest host arrival time that may be delivered now, or 0 for any.
 *
 * The emulator runs a frame of CPU time in a burst and then sleeps, so
 * "now - emulated time" swings by up to a frame. Its maximum (reached at the
 * start of each frame) is the offset at which emulated time follows real time.
 * Bytes arriving while the emulator sleeps belong to emulated time that has
 * already run, so every byte is delayed by a fixed latency of at least a frame
 * and released at "arrival + latency" in emulated time: the timing between
 * notes is kept, and the constant delay can be compensated in the sequencer
 * (e.g. Recomposer's ST+). The offset follows increases immediately
 * (emulation fell behind) and decreases slowly (1% of elapsed time). */
static UINT64
midiin_until(CMMIDI midi)
{
	UINT64 now;
	UINT32 clock, elapsed;
	UINT64 step;
	SINT64 diff, decay;

	if (cmmidi_midiin_latency_ms == 0 || pccore.realclock == 0) {
		return 0;
	}
	now = mach_absolute_time();
	clock = CPU_CLOCK + CPU_BASECLOCK - CPU_REMCLOCK;
	elapsed = clock - midi->inclock;
	midi->inclock = clock;

	if (midi->inemu == 0 || elapsed >= pccore.realclock) {
		/* first call, or idle for more than a second: resync */
		midi->inemu = now;
		midi->inoffset = 0;
		return now - ms2host(cmmidi_midiin_latency_ms);
	}
	step = ms2host(1) * elapsed / (pccore.realclock / 1000);
	midi->inemu += step;
	diff = (SINT64)(now - midi->inemu);
	if (diff > midi->inoffset) {
		midi->inoffset = diff;
	}
	else {
		decay = (SINT64)(step / 100);
		midi->inoffset -= MIN(midi->inoffset - diff, decay);
	}
	return midi->inemu + midi->inoffset - ms2host(cmmidi_midiin_latency_ms);
}

#ifndef NDEBUG
/* NP2_DEBUG_MIDICLK=1: log "<emulated ms> <delivery ms>" for every output
 * message to midiclk.log, to measure output timing against emulated time. */
static FILE *s_clklog;
static int s_clklog_checked;
static UINT32 s_clklog_lastclock;
static double s_clklog_emums;

static void
midiclk_log(UINT64 timestamp)
{
	static mach_timebase_info_data_t tb;
	UINT32 clock;

	if (!s_clklog_checked) {
		const char *env = getenv("NP2_DEBUG_MIDICLK");
		s_clklog_checked = 1;
		if (env && env[0]) {
			s_clklog = fopen("midiclk.log", "w");
		}
		s_clklog_lastclock = CPU_CLOCK + CPU_BASECLOCK - CPU_REMCLOCK;
	}
	if (!s_clklog || pccore.realclock == 0) {
		return;
	}
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	clock = CPU_CLOCK + CPU_BASECLOCK - CPU_REMCLOCK;
	if ((UINT32)(clock - s_clklog_lastclock) >= pccore.realclock) {
		/* idle for a second or the counter was reset: start a new segment */
		fprintf(s_clklog, "gap\n");
	}
	else {
		s_clklog_emums += (double)(UINT32)(clock - s_clklog_lastclock) * 1000.0 / pccore.realclock;
	}
	s_clklog_lastclock = clock;
	if (timestamp == 0) {
		timestamp = mach_absolute_time();
	}
	fprintf(s_clklog, "%.3f %.3f\n", s_clklog_emums, (double)timestamp * tb.numer / tb.denom / 1e6);
}
#else
#define midiclk_log(timestamp)
#endif

static void
midi_send(CMMIDI midi, const UINT8 *buf, UINT leng)
{
	UINT64 timestamp = midi_timestamp(midi);

	midiclk_log(timestamp);
	midirec_event(buf, leng, timestamp ? timestamp : mach_absolute_time());
	midiport_send(midi->hmidiout, buf, leng, timestamp);
}

static UINT
module2number(const char *module)
{
	int i;

	for (i = 0; i < NELEMENTS(cmmidi_mdlname); i++) {
		if (milstr_extendcmp(module, cmmidi_mdlname[i])) {
			return i;
		}
	}
	return MIDI_OTHER;
}

static void
sendexclusive(CMMIDI midi, const UINT8 *buf, UINT leng)
{

	if (midi->opened & CMMIDI_MIDIOUT) {
		midi_send(midi, buf, leng);
	}
#if defined(VERMOUTH_LIB)
	else if (midi->opened & CMMIDI_VERMOUTH) {
		midiout_longmsg(midi->vermouth, buf, leng);
	}
#endif
}

static void
midiout_none(CMMIDI midi, UINT32 msg, UINT cnt)
{

	/* Nothing to do */
}

static void
midiout_device(CMMIDI midi, UINT32 msg, UINT cnt)
{
	UINT8 buf[3];
	UINT i;

	for (i = 0; i < cnt; i++, msg >>= 8) {
		buf[i] = msg & 0xff;
	}
	midi_send(midi, buf, cnt);
}

#if defined(VERMOUTH_LIB)
static void
midiout_vermouth(CMMIDI midi, UINT32 msg, UINT cnt)
{

	sound_sync();
	midiout_shortmsg(midi->vermouth, msg);
}

static void SOUNDCALL
vermouth_getpcm(MIDIHDL hdl, SINT32 *pcm, UINT count)
{
	const SINT32 *ptr;
	UINT size;

	while (count) {
		size = count;
		ptr = midiout_get(hdl, &size);
		if (ptr == NULL) {
			break;
		}
		count -= size;
		do {
			pcm[0] += ptr[0];
			pcm[1] += ptr[1];
			ptr += 2;
			pcm += 2;
		} while (--size);
	}
}
#endif

static void
midireset(CMMIDI midi)
{
	const UINT8 *excv;
	UINT excvsize;
	UINT8 work[4];

	switch (midi->midimodule) {
	case MIDI_GM:
		excv = EXCV_GMRESET;
		excvsize = sizeof(EXCV_GMRESET);
		break;

	case MIDI_CM300:
	case MIDI_CM500GS:
	case MIDI_SC55:
	case MIDI_SC88:
	case MIDI_GS:
		excv = EXCV_GSRESET;
		excvsize = sizeof(EXCV_GSRESET);
		break;

	case MIDI_XG:
		excv = EXCV_XGRESET;
		excvsize = sizeof(EXCV_XGRESET);
		break;

	case MIDI_MT32:
	case MIDI_CM32L:
	case MIDI_CM64:
	case MIDI_CM500LA:
	case MIDI_LA:
		excv = EXCV_MTRESET;
		excvsize = sizeof(EXCV_MTRESET);
		break;

	default:
		excv = NULL;
		excvsize = 0;
		break;
	}
	if (excv) {
		sendexclusive(midi, excv, excvsize);
	}

	work[1] = 0x7b;
	work[2] = 0x00;
	for (work[0] = 0xb0; work[0] < 0xc0; work[0]++) {
		(*midi->outfn)(midi, MIDIOUTS3(work), 3);
	}
}

static void
midisetparam(CMMIDI midi)
{
	MIDICH mch;
	UINT i, j;

	mch = midi->mch;
	sound_sync();
	for (i = 0; i < 16; i++, mch++) {
		if (mch->press != 0xff) {
			(*midi->outfn)(midi, MIDIOUTS(0xa0+i, mch->press, 0),3);
		}
		if (mch->bend != 0xffff) {
			(*midi->outfn)(midi, (mch->bend << 8) + 0xe0+i, 3);
		}
		for (j = 0; j < sizeof(midictrltbl) / sizeof(UINT8); j++) {
			if (mch->ctrl[j+1] != 0xff) {
				(*midi->outfn)(midi, MIDIOUTS(0xb0+i, midictrltbl[j], mch->ctrl[j+1]), 3);
			}
		}
		if (mch->prog != 0xff) {
			(*midi->outfn)(midi, MIDIOUTS(0xc0+i, mch->prog, 0), 3);
		}
	}
}


// ----

#ifndef NDEBUG
/* NP2_DEBUG_MIDIINLOG=1: log "<arrival ms> <delivered ms> <released-at ms> <byte>"
 * for every MIDI-IN byte handed to the MPU, to midiin.log. */
static void
midiin_log(CMMIDI midi, UINT64 until, UINT8 data)
{
	static FILE *fp;
	static int checked;
	static mach_timebase_info_data_t tb;

	if (!checked) {
		const char *env = getenv("NP2_DEBUG_MIDIINLOG");
		checked = 1;
		if (env && env[0]) {
			fp = fopen("midiin.log", "w");
		}
		mach_timebase_info(&tb);
	}
	if (fp) {
		double k = (double)tb.numer / tb.denom / 1e6;
		fprintf(fp, "%.3f %.3f %.3f %02x\n",
			midiport_lastreadtime(midi->hmidiin) * k, mach_absolute_time() * k, until * k, data);
		fflush(fp);
	}
}
#else
#define midiin_log(midi, until, data)
#endif

static UINT
midiread(COMMNG self, UINT8 *data)
{
	CMMIDI midi = (CMMIDI)(self + 1);
	UINT64 until;

	if (midi->opened & CMMIDI_MIDIIN) {
		until = midiin_until(midi);
		if (midiport_read(midi->hmidiin, data, until)) {
			midiin_log(midi, until, *data);
			return 1;
		}
	}
	return 0;
}

static UINT
midiwrite(COMMNG self, UINT8 data)
{
	CMMIDI midi;
	MIDICH mch;
	int type;

	midi = (CMMIDI)(self + 1);
	switch (data) {
	case MIDI_TIMING:
	case MIDI_START:
	case MIDI_CONTINUE:
	case MIDI_STOP:
		/* the MPU's clock (NP2kai patch 0015), when turned on */
		if (mpu98ii_midiclockout && (midi->opened & CMMIDI_MIDIOUT)) {
			midi_send(midi, &data, 1);
		}
		return 1;

	case MIDI_ACTIVESENSE:
	case MIDI_SYSTEMRESET:
		return 1;
	}
	if (midi->midictrl == MIDICTRL_READY) {
		if (data & 0x80) {
			midi->mpos = 0;
			switch (data & 0xf0) {
			case 0xc0:
			case 0xd0:
				midi->midictrl = MIDICTRL_2BYTES;
				midi->midilast = data;
				break;

			case 0x80:
			case 0x90:
			case 0xa0:
			case 0xb0:
			case 0xe0:
				midi->midictrl = MIDICTRL_3BYTES;
				midi->midilast = data;
				break;

			default:
				switch (data) {
				case MIDI_EXCLUSIVE:
					midi->midictrl = MIDICTRL_EXCLUSIVE;
					break;

				case MIDI_TIMECODE:
					midi->midictrl = MIDICTRL_TIMECODE;
					break;

				case MIDI_SONGPOS:
					midi->midictrl = MIDICTRL_SYSTEM;
					midi->midisyscnt = 3;
					break;

				case MIDI_SONGSELECT:
					midi->midictrl = MIDICTRL_SYSTEM;
					midi->midisyscnt = 2;
					break;

				case MIDI_TUNEREQUEST:
					midi->midictrl = MIDICTRL_SYSTEM;
					midi->midisyscnt = 1;
					break;

				default:
					return(1);
				}
				break;
			}
		} else {
			/* running status */
			midi->buffer[0] = midi->midilast;
			midi->mpos = 1;
			switch (midi->midilast & 0xf0)
			{
				case 0xc0:
				case 0xd0:
					midi->midictrl = MIDICTRL_2BYTES;
					break;

				case 0x80:
				case 0x90:
				case 0xa0:
				case 0xb0:
				case 0xe0:
					midi->midictrl = MIDICTRL_3BYTES;
					break;
				default:
					return 1;
			}
		}
	}
	midi->buffer[midi->mpos] = data;
	midi->mpos++;

	switch (midi->midictrl) {
	case MIDICTRL_2BYTES:
		if (midi->mpos >= 2) {
			midi->buffer[1] &= 0x7f;
			mch = midi->mch + (midi->buffer[0] & 0xf);
			switch (midi->buffer[0] & 0xf0) {
			case 0xa0:
				mch->press = midi->buffer[1];
				break;

			case 0xc0:
				if (midi->def_en) {
					type = midi->def.ch[midi->buffer[0] & 0x0f];
					if (type < MIMPI_RHYTHM) {
						midi->buffer[1] = midi->def.map[type][midi->buffer[1]];
					}
				}
				mch->prog = midi->buffer[1];
				break;
			}
			(*midi->outfn)(midi, MIDIOUTS2(midi->buffer), 2);
			midi->midictrl = MIDICTRL_READY;
			return 2;
		}
		break;

	case MIDICTRL_3BYTES:
		if (midi->mpos >= 3) {
			midi->buffer[1] &= 0x7f;
			midi->buffer[2] &= 0x7f;
			mch = midi->mch + (midi->buffer[0] & 0xf);
			switch (midi->buffer[0] & 0xf0) {
			case 0xb0:
				if (midi->buffer[1] == 123) {
					mch->press = 0;
					mch->bend = 0x4000;
					mch->ctrl[1+1] = 0;	// Modulation
					mch->ctrl[5+1] = 127;	// Explession
					mch->ctrl[6+1] = 0;	// Hold
					mch->ctrl[7+1] = 0;	// Portament
					mch->ctrl[8+1] = 0;	// Sostenute
					mch->ctrl[9+1] = 0;	// Soft
				} else {
					mch->ctrl[midictrlindex[midi->buffer[1]]] = midi->buffer[2];
				}
				break;

			case 0xe0:
				mch->bend = LOADINTELWORD(midi->buffer + 1);
				break;
			}
			(*midi->outfn)(midi, MIDIOUTS3(midi->buffer), 3);
			midi->midictrl = MIDICTRL_READY;
			return 3;
		}
		break;

	case MIDICTRL_EXCLUSIVE:
		if (data == MIDI_EOX) {
			sendexclusive(midi, midi->buffer, midi->mpos);
			midi->midictrl = MIDICTRL_READY;
			return midi->mpos;
		} else if (midi->mpos >= MIDI_BUFFER) {	// overflow
			midi->midictrl = MIDICTRL_READY;
		}
		break;

	case MIDICTRL_TIMECODE:
		if (midi->mpos >= 2) {
			if ((data == 0x7e) || (data == 0x7f)) {
				// same as exclusive
				midi->midictrl = MIDICTRL_EXCLUSIVE;
			} else {
				midi->midictrl = MIDICTRL_READY;
				return 2;
			}
		}
		break;

	case MIDICTRL_SYSTEM:
		if (midi->mpos >= midi->midisyscnt) {
			midi->midictrl = MIDICTRL_READY;
			return midi->midisyscnt;
		}
		break;
	}
	return 0;
}

static UINT8
midigetstat(COMMNG self)
{

	return 0x00;
}

static INTPTR
midimsg(COMMNG self, UINT msg, INTPTR param)
{
	CMMIDI midi;
	COMFLAG	flag;

	midi = (CMMIDI)(self + 1);
	switch (msg) {
	case COMMSG_MIDIRESET:
		midireset(midi);
		return 1;

	case COMMSG_SETFLAG:
		flag = (COMFLAG)param;
		if ((flag) &&
		    (flag->size == sizeof(_COMFLAG) + sizeof(midi->mch)) &&
		    (flag->sig == COMSIG_MIDI)) {
			CopyMemory(midi->mch, flag + 1, sizeof(midi->mch));
			midisetparam(midi);
			return 1;
		}
		break;

	case COMMSG_GETFLAG:
		flag = (COMFLAG)_MALLOC(sizeof(_COMFLAG) + sizeof(midi->mch), "MIDI FLAG");
		if (flag) {
			flag->size = sizeof(_COMFLAG) + sizeof(midi->mch);
			flag->sig = COMSIG_MIDI;
			flag->ver = 0;
			flag->param = 0;
			CopyMemory(flag + 1, midi->mch, sizeof(midi->mch));
			return (INTPTR)flag;
		}
		break;
	}
	return 0;
}

static void
midirelease(COMMNG self)
{
	CMMIDI midi;
	UINT i;

	midi = (CMMIDI)(self + 1);
	for (i = 0; i < NELEMENTS(s_instances); i++) {
		if (s_instances[i] == midi) {
			s_instances[i] = NULL;
		}
	}
	if (midi->opened & CMMIDI_MIDIIN) {
		midiport_closein(midi->hmidiin);
	}
	if (midi->opened & CMMIDI_MIDIOUT) {
		midiport_closeout(midi->hmidiout);
	}
#if defined(VERMOUTH_LIB)
	if (midi->opened & CMMIDI_VERMOUTH) {
		midiout_destroy(midi->vermouth);
	}
#endif
	_MFREE(self);
}


// ----

void
cmmidi_initailize(void)
{
	UINT i;

	ZeroMemory(midictrlindex, sizeof(midictrlindex));
	for (i = 0; i < sizeof(midictrltbl) / sizeof(UINT8); i++) {
		midictrlindex[midictrltbl[i]] = (UINT8)(i + 1);
	}
	midictrlindex[32] = 1;
}

/**
 * @param midiout	output selection (see midiport.h), or "VERMOUTH"
 * @param midiin	input selection (see midiport.h)
 */
COMMNG
cmmidi_create(const UINT device, const char *midiout, const char *midiin, const char *module)
{
	COMMNG ret;
	CMMIDI midi;
	void (*outfn)(CMMIDI midi, UINT32 msg, UINT cnt);
	MIDIPORTIN hmidiin = NULL;
	MIDIPORTOUT hmidiout = NULL;
#if defined(VERMOUTH_LIB)
	MIDIHDL vermouth = NULL;
#endif
	int opened = 0;

	(void)device;

	/* MIDI-IN */
	hmidiin = midiport_openin(midiin);
	if (hmidiin) {
		opened |= CMMIDI_MIDIIN;
	}

	/* MIDI-OUT */
	outfn = midiout_none;
#if defined(VERMOUTH_LIB)
	if (midiout && !milstr_cmp(midiout, cmmidi_vermouth)) {
		vermouth = midiout_create(vermouth_module, 512);
		if (vermouth != NULL) {
			outfn = midiout_vermouth;
			opened |= CMMIDI_VERMOUTH;
		}
	}
	else
#endif
	{
		hmidiout = midiport_openout(midiout);
		if (hmidiout) {
			outfn = midiout_device;
			opened |= CMMIDI_MIDIOUT;
		}
	}
	if (!opened) {
		return NULL;
	}
	ret = (COMMNG)_MALLOC(sizeof(_COMMNG) + sizeof(_CMMIDI), "MIDI");
	if (ret == NULL) {
		midiport_closein(hmidiin);
		midiport_closeout(hmidiout);
#if defined(VERMOUTH_LIB)
		if (vermouth) {
			midiout_destroy(vermouth);
		}
#endif
		return NULL;
	}
	ret->connect = COMCONNECT_MIDI;
	ret->read = midiread;
	ret->write = midiwrite;
	ret->getstat = midigetstat;
	ret->msg = midimsg;
	ret->release = midirelease;

	midi = (CMMIDI)(ret + 1);
	ZeroMemory(midi, sizeof(_CMMIDI));
	midi->opened = opened;
	midi->outfn = outfn;
	midi->midictrl = MIDICTRL_READY;
	midi->hmidiin = hmidiin;
	midi->hmidiout = hmidiout;
#if defined(VERMOUTH_LIB)
	midi->vermouth = vermouth;
	if (opened & CMMIDI_VERMOUTH) {
		sound_streamregist((void *)vermouth, (SOUNDCB)vermouth_getpcm);
	}
#endif
	midi->midilast = 0x80;
	midi->midimodule = (UINT8)module2number(module);
	FillMemory(midi->mch, sizeof(midi->mch), 0xff);
	for (UINT i = 0; i < NELEMENTS(s_instances); i++) {
		if (s_instances[i] == NULL) {
			s_instances[i] = midi;
			break;
		}
	}
	return ret;
}

/* Silences the external devices right away (All Sound Off, All Notes Off and
 * Reset All Controllers' sustain on every channel), e.g. before the app is
 * suspended or the output device changes. The guest is not told. */
void
cmmidi_allnotesoff(void)
{
	UINT i;
	UINT8 msg[3];

	for (i = 0; i < NELEMENTS(s_instances); i++) {
		CMMIDI midi = s_instances[i];
		if (midi == NULL || !(midi->opened & CMMIDI_MIDIOUT)) {
			continue;
		}
		for (msg[0] = 0xb0; msg[0] < 0xc0; msg[0]++) {
			msg[1] = 0x40;	/* sustain off */
			msg[2] = 0x00;
			midiport_send(midi->hmidiout, msg, 3, 0);
			msg[1] = 0x78;	/* all sound off */
			midiport_send(midi->hmidiout, msg, 3, 0);
			msg[1] = 0x7b;	/* all notes off */
			midiport_send(midi->hmidiout, msg, 3, 0);
		}
	}
}
