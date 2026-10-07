/**
 * @file	main.m
 * @brief	iOS entry point
 *
 * SDL2 provides the real main() (UIApplicationMain) and calls SDL_main().
 * The emulator keeps its data (BIOS, fonts, disk images, np2kai.cfg) under
 * Documents/sdlnp21kai/ so that the Files app can access it.
 */

#import <Foundation/Foundation.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_main.h>
#include <stdlib.h>
#include <unistd.h>

#include "compiler.h"
#include "debugkeys.h"
#include "debugmidi.h"
#include "keybar.h"
#include "midiport.h"
#include "settings.h"

extern int np2_main(int argc, char *argv[]);

int SDL_main(int argc, char *argv[])
{
	@autoreleasepool {
		NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
		/* sdl/np2.c uses $XDG_CONFIG_HOME/<appname>/ as the data directory. */
		setenv("XDG_CONFIG_HOME", documents.fileSystemRepresentation, 1);
		NSString *dataDir = [documents stringByAppendingPathComponent:@"sdlnp21kai"];
		[[NSFileManager defaultManager] createDirectoryAtPath:dataDir withIntermediateDirectories:YES attributes:nil error:nil];
		/* The sandbox path changes on reinstall, so disk images in the cfg are
		 * given relative to the data directory. */
		chdir(dataDir.fileSystemRepresentation);
	}
	/* The key bar sits at the bottom edge: keep the home indicator out of the way. */
	SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");
	settings_initialize();
	midiport_initialize();
	debugmidi_start();
	debugkeys_start();
	keybar_initialize();
	return np2_main(argc, argv);
}
