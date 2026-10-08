/**
 * @file	hinge.m
 * @brief	The hinge of a foldable (iPhone Duo)
 *
 * Modelled on mRemote's HingePostureReader. UIHingeInteraction, unlike
 * SwiftUI's onHingeChange, also delivers the state the view starts in.
 */

#include "hinge.h"

#if defined(__IPHONE_27_1) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_27_1
#define HAVE_HINGE 1

API_AVAILABLE(ios(27.1))
static NP2HingePosture posture_of(UIHinge *hinge)
{
	if (hinge == nil) {
		return NP2HingePostureUnavailable;	/* left a hierarchy with a hinge */
	}
	switch (hinge.status) {
		case UIHingeStatusClosed:
			return NP2HingePostureClosed;
		case UIHingeStatusPartiallyOpen:
			return NP2HingePosturePartiallyOpen;
		case UIHingeStatusFullyOpen:
			return NP2HingePostureFullyOpen;
		default:
			return NP2HingePostureUnavailable;
	}
}
#endif

void hinge_observe(UIView *view, void (^handler)(NP2HingePosture posture))
{
#ifdef HAVE_HINGE
	if (@available(iOS 27.1, *)) {
		[view addInteraction:[[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
			(void)interaction;
			handler(posture_of(update.hinge));
		}]];
		return;
	}
#endif
	(void)view;
	handler(NP2HingePostureUnavailable);
}
