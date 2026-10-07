/**
 * @file	debugscreen.h
 * @brief	Text screen dump for testing on the simulator (debug builds only)
 */

#pragma once

/* Writes screen.txt when debugscreen.req exists. Called from the debugkeys thread. */
void debugscreen_poll(void);
