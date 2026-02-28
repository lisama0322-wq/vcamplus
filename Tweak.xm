#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

//
// VCam Plus - Virtual camera tweak for iOS 16 + Dopamine rootless
//
// Works in:
//   - All UIKit-based apps (hook on AVCaptureVideoDataOutput)
//   - Safari web pages (WebContent process, same hook)
//
// Setup:
//   1. Place video at /var/mobile/Library/Caches/vcamplus/video.mp4
//   2. Create empty file at /var/mobile/Library/Caches/vcamplus/enabled
//   Tweak will then replace camera output with the video, looping continuously.
//

#define VCAM_DIR   @"/var/mobile/Library/Caches/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"

// ============================================================
// Global state (protected by gLock)
// ============================================================
static NSLock               *gLock        = nil;
static AVAssetReader        *gReader      = nil;
static AVAssetReaderTrackOutput *gOutput  = nil;
static NSMutableSet         *gProxies     = nil;  // strong refs to proxy delegates

// ============================================================
// Helpers
// ============================================================
static BOOL vcam_isEnabled(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:VCAM_FLAG] && [fm fileExistsAtPath:VCAM_VIDEO];
}

// Must be called with gLock held.
static BOOL vcam_openReader(void) {
    gReader = nil;
    gOutput = nil;

    NSURL *url = [NSURL fileURLWithPath:VCAM_VIDEO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];

    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return NO;
    AVAssetTrack *track = tracks[0];

    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!reader || err) return NO;

    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) return NO;

    gReader = reader;
    gOutput = output;
    return YES;
}

// Returns a retained CMSampleBufferRef with retimed presentation timestamp
// matching |original|, or NULL if replacement is disabled / unavailable.
static CMSampleBufferRef vcam_nextFrame(CMSampleBufferRef original) {
    if (!vcam_isEnabled()) return NULL;

    [gLock lock];

    // Lazily open reader on first call.
    if (!gReader) {
        vcam_openReader();
    }

    CMSampleBufferRef frame = nil;
    if (gReader) {
        frame = [gOutput copyNextSampleBuffer];
        // If video ended, loop from beginning.
        if (!frame || gReader.status != AVAssetReaderStatusReading) {
            gReader = nil;
            gOutput = nil;
            if (vcam_openReader()) {
                frame = [gOutput copyNextSampleBuffer];
            }
        }
    }

    [gLock unlock];

    if (!frame) return NULL;

    // Retime the frame to match the live camera stream so there are no
    // timestamp discontinuities downstream.
    CMSampleTimingInfo timing = {
        .duration               = CMSampleBufferGetDuration(original),
        .presentationTimeStamp  = CMSampleBufferGetPresentationTimeStamp(original),
        .decodeTimeStamp        = kCMTimeInvalid
    };

    CMSampleBufferRef timedFrame = NULL;
    OSStatus st = CMSampleBufferCreateCopyWithNewTiming(
        kCFAllocatorDefault, frame, 1, &timing, &timedFrame);
    CFRelease(frame);

    if (st != noErr || !timedFrame) return NULL;
    return timedFrame;  // caller must CFRelease
}

// ============================================================
// Proxy delegate
// Wraps the real AVCaptureVideoDataOutputSampleBufferDelegate
// and substitutes video frames.
// ============================================================
@interface VCamProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@end

@implementation VCamProxyDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id real = self.realDelegate;
    if (!real) return;

    CMSampleBufferRef replaced = vcam_nextFrame(sampleBuffer);
    if (replaced) {
        [real captureOutput:output
      didOutputSampleBuffer:replaced
             fromConnection:connection];
        CFRelease(replaced);
    } else {
        [real captureOutput:output
      didOutputSampleBuffer:sampleBuffer
             fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id real = self.realDelegate;
    if ([real respondsToSelector:_cmd]) {
        [real captureOutput:output
        didDropSampleBuffer:sampleBuffer
             fromConnection:connection];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.realDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.realDelegate respondsToSelector:aSelector]) return self.realDelegate;
    return [super forwardingTargetForSelector:aSelector];
}

@end

// ============================================================
// Hooks
// ============================================================
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate &&
        ![sampleBufferDelegate isKindOfClass:[VCamProxyDelegate class]]) {
        VCamProxyDelegate *proxy = [VCamProxyDelegate new];
        proxy.realDelegate = sampleBufferDelegate;
        // Keep a strong reference so the proxy is not deallocated while the
        // delegate is registered (AVCaptureVideoDataOutput only holds weak ref).
        [gProxies addObject:proxy];
        %orig(proxy, sampleBufferCallbackQueue);
    } else {
        %orig;
    }
}

%end

// ============================================================
// Constructor
// ============================================================
%ctor {
    @autoreleasepool {
        gLock   = [[NSLock alloc] init];
        gProxies = [NSMutableSet new];

        // Create the cache directory so the user just needs to drop files in.
        [[NSFileManager defaultManager]
            createDirectoryAtPath:VCAM_DIR
          withIntermediateDirectories:YES
                         attributes:nil
                               error:nil];
    }
}
