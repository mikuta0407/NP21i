/*
 * Stub for SDL_ttf.
 *
 * sdl/fontmng.c includes <SDL_ttf.h> unconditionally, but only uses it when
 * SUPPORT_SDL_TTF is defined. The iOS port does not use SDL_ttf (a CoreText
 * based font manager is planned), so an empty header is enough.
 */
#pragma once
