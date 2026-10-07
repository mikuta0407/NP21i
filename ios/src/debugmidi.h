/**
 * @file	debugmidi.h
 * @brief	MIDI loopback tools for testing on the simulator (debug builds only)
 */

#pragma once

/* Call after midiport_initialize() so the virtual endpoints exist. */
void debugmidi_start(void);
