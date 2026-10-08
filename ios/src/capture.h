/**
 * @file	capture.h
 * @brief	Screenshots and videos of the PC-98 screen (not the app around it)
 */

#pragma once

#import <UIKit/UIKit.h>

/* The PC-98 screen as it is shown now, at its own size (640x400...), or
 * nil before the emulator draws. */
UIImage *capture_screenimage(void);

/* Saves a PNG to captures/ in the data directory and offers to share it
 * (Photos, AirDrop...). */
void capture_screenshot(UIViewController *host);

/* Records the PC-98 screen (scaled up 2x, nearest pixel) and its sound to
 * an MP4 in captures/. Stopping offers to share it. */
BOOL capture_isrecording(void);
void capture_startrecording(void);
void capture_stoprecording(UIViewController *host);
