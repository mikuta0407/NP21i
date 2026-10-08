/**
 * @file	capture.m
 * @brief	Screenshots and videos of the PC-98 screen (not the app around it)
 *
 * The screen is read from scrnmng.dispsurf, what SDL is given to show; the
 * sound from the mixer (NP2kai patch 0013, soundmng_iostap). Both happen on
 * the main thread, where the emulator runs, so no locking is needed.
 *
 * A video's frames are timed by the host clock (30 a second) and its sound
 * by the samples mixed; they drift apart only when the emulator falls
 * behind, as they do on screen.
 */

#include "compiler.h"
#include "capture.h"
#include "sdlcompat.h"
#include <pccore.h>
#include <scrnmng.h>
#include <soundmng.h>

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

static NSString *captures_dir(void)
{
	NSString *dir = [[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:@"captures"];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return dir;
}

static NSString *capture_name(NSString *ext)
{
	NSDateFormatter *format = [NSDateFormatter new];
	format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
	format.dateFormat = @"yyyyMMdd-HHmmss";
	return [NSString stringWithFormat:@"NP21 %@.%@", [format stringFromDate:[NSDate date]], ext];
}

static void share(UIViewController *host, NSURL *url)
{
	UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
	UIPopoverPresentationController *popover = sheet.popoverPresentationController;
	if (popover) {
		popover.sourceView = host.view;
		popover.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
		popover.permittedArrowDirections = 0;
	}
	[host presentViewController:sheet animated:YES completion:nil];
}

static CGImageRef create_screen_cgimage(void)
{
	SDL_Surface *src = (SDL_Surface *)scrnmng.dispsurf;
	if (src == NULL || src->w <= 0 || src->h <= 0) {
		return NULL;
	}
#if USE_SDL >= 3
	SDL_Surface *rgba = SDL_ConvertSurface(src, SDL_PIXELFORMAT_ABGR8888);
#else
	SDL_Surface *rgba = SDL_ConvertSurfaceFormat(src, SDL_PIXELFORMAT_ABGR8888, 0);
#endif
	if (rgba == NULL) {
		return NULL;
	}
	/* ABGR8888 is R, G, B, A in memory */
	CFDataRef data = CFDataCreate(NULL, rgba->pixels, (CFIndex)rgba->pitch * rgba->h);
	CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGImageRef image = CGImageCreate((size_t)rgba->w, (size_t)rgba->h, 8, 32, (size_t)rgba->pitch, space,
		kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast, provider, NULL, false, kCGRenderingIntentDefault);
	CGColorSpaceRelease(space);
	CGDataProviderRelease(provider);
	CFRelease(data);
#if USE_SDL >= 3
	SDL_DestroySurface(rgba);
#else
	SDL_FreeSurface(rgba);
#endif
	return image;
}

UIImage *capture_screenimage(void)
{
	CGImageRef cg = create_screen_cgimage();
	if (cg == NULL) {
		return nil;
	}
	UIImage *image = [UIImage imageWithCGImage:cg];
	CGImageRelease(cg);
	return image;
}

void capture_screenshot(UIViewController *host)
{
	UIImage *image = capture_screenimage();
	NSData *png = UIImagePNGRepresentation(image);
	if (png == nil) {
		return;
	}
	NSString *path = [captures_dir() stringByAppendingPathComponent:capture_name(@"png")];
	if (![png writeToFile:path atomically:YES]) {
		return;
	}
	NSLog(@"capture: %@", path.lastPathComponent);
	share(host, [NSURL fileURLWithPath:path]);
}

// ---- video

static AVAssetWriter *s_writer;
static AVAssetWriterInput *s_video;
static AVAssetWriterInput *s_audio;
static AVAssetWriterInputPixelBufferAdaptor *s_adaptor;
static CADisplayLink *s_link;
static CFTimeInterval s_start;
static CMTime s_lastFrame;
static int64_t s_audioFrames;
static UINT s_rate;
static CMAudioFormatDescriptionRef s_audioFormat;

@interface NP2CaptureTicker : NSObject
@end

static void add_frame(void);

@implementation NP2CaptureTicker
- (void)tick:(CADisplayLink *)link
{
	(void)link;
	add_frame();
}
@end

static NP2CaptureTicker *s_ticker;

static void add_frame(void)
{
	if (s_writer.status != AVAssetWriterStatusWriting || !s_video.readyForMoreMediaData) {
		return;
	}
	CMTime time = CMTimeMakeWithSeconds(CACurrentMediaTime() - s_start, 600);
	if (CMTIME_COMPARE_INLINE(time, <=, s_lastFrame)) {
		return;
	}
	CGImageRef image = create_screen_cgimage();
	if (image == NULL) {
		return;
	}
	CVPixelBufferRef buffer = NULL;
	if (CVPixelBufferPoolCreatePixelBuffer(NULL, s_adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess) {
		CGImageRelease(image);
		return;
	}
	CVPixelBufferLockBaseAddress(buffer, 0);
	size_t width = CVPixelBufferGetWidth(buffer);
	size_t height = CVPixelBufferGetHeight(buffer);
	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width, height, 8,
		CVPixelBufferGetBytesPerRow(buffer), space, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(space);
	CGContextSetRGBFillColor(context, 0, 0, 0, 1);
	CGContextFillRect(context, CGRectMake(0, 0, width, height));
	/* aspect fit, the pixels kept sharp (the screen may change size) */
	CGFloat w = CGImageGetWidth(image), h = CGImageGetHeight(image);
	CGFloat scale = MIN(width / w, height / h);
	CGContextSetInterpolationQuality(context, kCGInterpolationNone);
	CGContextDrawImage(context, CGRectMake((width - w * scale) / 2, (height - h * scale) / 2, w * scale, h * scale), image);
	CGContextRelease(context);
	CVPixelBufferUnlockBaseAddress(buffer, 0);
	CGImageRelease(image);
	if ([s_adaptor appendPixelBuffer:buffer withPresentationTime:time]) {
		s_lastFrame = time;
	}
	CVPixelBufferRelease(buffer);
}

static void add_sound(const SINT16 *samples, UINT bytes)
{
	UINT frames = bytes / (2 * sizeof(SINT16));
	if (frames == 0 || s_writer.status != AVAssetWriterStatusWriting || !s_audio.readyForMoreMediaData) {
		s_audioFrames += frames;		/* keeps the timeline when dropped */
		return;
	}
	CMBlockBufferRef block = NULL;
	if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, bytes, NULL, NULL, 0, bytes, kCMBlockBufferAssureMemoryNowFlag, &block) != noErr) {
		return;
	}
	CMBlockBufferReplaceDataBytes(samples, block, 0, bytes);
	CMSampleBufferRef sample = NULL;
	CMTime time = CMTimeMake(s_audioFrames, (int32_t)s_rate);
	if (CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block, s_audioFormat, frames, time, NULL, &sample) == noErr) {
		[s_audio appendSampleBuffer:sample];
		CFRelease(sample);
	}
	CFRelease(block);
	s_audioFrames += frames;
}

BOOL capture_isrecording(void)
{
	return s_writer != nil;
}

void capture_startrecording(void)
{
	if (s_writer || scrnmng.width <= 0 || scrnmng.height <= 0) {
		return;
	}
	int factor = (scrnmng.width <= 640) ? 2 : 1;
	int width = (scrnmng.width * factor) & ~1;
	int height = (scrnmng.height * factor) & ~1;
	NSURL *url = [NSURL fileURLWithPath:[captures_dir() stringByAppendingPathComponent:capture_name(@"mp4")]];
	NSError *error = nil;
	AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
	if (writer == nil) {
		NSLog(@"capture: %@", error.localizedDescription);
		return;
	}
	AVAssetWriterInput *video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
		AVVideoCodecKey: AVVideoCodecTypeH264,
		AVVideoWidthKey: @(width),
		AVVideoHeightKey: @(height),
		AVVideoCompressionPropertiesKey: @{ AVVideoAverageBitRateKey: @(8000000) },
	}];
	video.expectsMediaDataInRealTime = YES;
	AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
		assetWriterInputPixelBufferAdaptorWithAssetWriterInput:video sourcePixelBufferAttributes:@{
			(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
			(NSString *)kCVPixelBufferWidthKey: @(width),
			(NSString *)kCVPixelBufferHeightKey: @(height),
		}];
	[writer addInput:video];

	s_rate = np2cfg.samplingrate ? np2cfg.samplingrate : 44100;
	AudioStreamBasicDescription pcm = {
		.mSampleRate = s_rate,
		.mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
		.mBytesPerPacket = 4,
		.mFramesPerPacket = 1,
		.mBytesPerFrame = 4,
		.mChannelsPerFrame = 2,
		.mBitsPerChannel = 16,
	};
	if (s_audioFormat) {
		CFRelease(s_audioFormat);
		s_audioFormat = NULL;
	}
	CMAudioFormatDescriptionCreate(NULL, &pcm, 0, NULL, 0, NULL, NULL, &s_audioFormat);
	AVAssetWriterInput *audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
		AVFormatIDKey: @(kAudioFormatMPEG4AAC),
		AVSampleRateKey: @(MIN(MAX(s_rate, 22050u), 48000u)),
		AVNumberOfChannelsKey: @2,
		AVEncoderBitRateKey: @192000,
	}];
	audio.expectsMediaDataInRealTime = YES;
	if ([writer canAddInput:audio]) {
		[writer addInput:audio];
	}
	else {
		audio = nil;
	}
	if (![writer startWriting]) {
		NSLog(@"capture: %@", writer.error.localizedDescription);
		return;
	}
	[writer startSessionAtSourceTime:kCMTimeZero];

	s_writer = writer;
	s_video = video;
	s_audio = audio;
	s_adaptor = adaptor;
	s_start = CACurrentMediaTime();
	s_lastFrame = kCMTimeNegativeInfinity;
	s_audioFrames = 0;
	if (audio) {
		soundmng_iostap = add_sound;
	}
	s_ticker = [NP2CaptureTicker new];
	s_link = [CADisplayLink displayLinkWithTarget:s_ticker selector:@selector(tick:)];
	s_link.preferredFrameRateRange = CAFrameRateRangeMake(30, 30, 30);
	[s_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	NSLog(@"capture: recording %dx%d to %@", width, height, url.lastPathComponent);
}

void capture_stoprecording(UIViewController *host)
{
	if (s_writer == nil) {
		return;
	}
	soundmng_iostap = NULL;
	[s_link invalidate];
	s_link = nil;
	s_ticker = nil;
	AVAssetWriter *writer = s_writer;
	[s_video markAsFinished];
	[s_audio markAsFinished];
	s_writer = nil;
	s_video = nil;
	s_audio = nil;
	s_adaptor = nil;
	[writer finishWritingWithCompletionHandler:^{
		dispatch_async(dispatch_get_main_queue(), ^{
			if (writer.status == AVAssetWriterStatusCompleted) {
				NSLog(@"capture: saved %@", writer.outputURL.lastPathComponent);
				if (host) {
					share(host, writer.outputURL);
				}
			}
			else {
				NSLog(@"capture: failed %@", writer.error.localizedDescription);
			}
		});
	}];
}
