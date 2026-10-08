/**
 * @file	openurl.h
 * @brief	Files and np21:// links given to the app
 *
 * Info.plist names NP2SceneDelegate (a subclass of SDL's) as the scene's
 * delegate, so that the URLs come here instead of becoming SDL drop events
 * (which lose the access to files outside the app).
 *
 * Files (Files' "open", the share sheet) go to keybar_openfile(). Links:
 *   np21://env/<name>             switch to the environment
 *   np21://slot/save/<1-6>        save the state to a slot
 *   np21://slot/load/<1-6>        go back to a slot (asks first)
 *   np21://fdd/<1|2>/<path>       insert an image (path in the data folder)
 *   np21://eject/<1|2>            eject a floppy
 *   np21://type?text=<text>       type the text (asks first)
 *   np21://reset                  reset (asks first)
 *   np21://screenshot             take a screenshot
 * Shortcuts' "Open URLs" can run them.
 */

#pragma once

#import <Foundation/Foundation.h>

/* Called once the app can show things (keybar.m): handles the URLs that
 * came while it started. */
void openurl_ready(void);

/* Testing: as if the URL was opened. */
void openurl_open(NSURL *url);
