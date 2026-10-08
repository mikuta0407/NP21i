/**
 * @file	midirec.h
 * @brief	Records the MIDI sent out to a Standard MIDI File
 */

#pragma once

#include "compiler.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Each message sent out (cmmidi.c), with the host time it is sent at. */
void midirec_event(const UINT8 *buf, UINT leng, UINT64 hosttime);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <UIKit/UIKit.h>

/* Recording starts at the first message after midirec_start(); stopping
 * writes a format 0 SMF (480 ticks a beat at 120 BPM, so a tick is about
 * a millisecond) to midi/ in the data directory and offers to share it. */
BOOL midirec_isrecording(void);
void midirec_start(void);
void midirec_stop(UIViewController *host);
/* Seconds since the first message, 0 before it. */
NSTimeInterval midirec_duration(void);
#endif
