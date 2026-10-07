/**
 * @file	compiler.h
 * @brief	compiler / platform settings for the iOS port
 *
 * Based on sdl/unix/compiler.h. Unlike the desktop build, SDL_main must not
 * be redefined here: on iOS SDL2 provides main() and calls SDL_main().
 */

#ifndef COMPILER_H
#define COMPILER_H

#include "compiler_base.h"

#include	<pthread.h>

#define	msgbox(title, msg)

#define	__ASSERT(s)

#define RESOURCE_US

#define NP2_SIZE_VGA

#define	GETTICK()			SDL_GetTicks()

#define	USE_SDL_JOYSTICK

#include <common/milstr.h>
#include <trace.h>

#endif  // COMPILER_H
