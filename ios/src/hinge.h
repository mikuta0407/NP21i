/**
 * @file	hinge.h
 * @brief	The hinge of a foldable (iPhone Duo)
 */

#pragma once

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, NP2HingePosture) {
	NP2HingePostureUnavailable,	/* no hinge, or an SDK / iOS without hinge APIs */
	NP2HingePostureClosed,
	NP2HingePosturePartiallyOpen,
	NP2HingePostureFullyOpen
};

/* Calls handler with the hinge's posture now and whenever it changes,
 * through a UIHingeInteraction added to view.
 *
 * iOS 27.1 tells the hinge's status and angle but not where it is. On the
 * iPhone Duo the inner display folds across its long side, through the
 * middle, so half open with the screen taller than wide is the laptop
 * posture: one half stands up, the other lies flat in front of the user.
 *
 * Built with an SDK older than iOS 27.1 (Xcode 27.1 beta), or run on an
 * older iOS, the posture is always NP2HingePostureUnavailable. */
void hinge_observe(UIView *view, void (^handler)(NP2HingePosture posture));
