#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import <UIKit/UIKit.h>

//
// VCam Plus v3 - Virtual camera for iOS 16 + Dopamine rootless
//
// Volume Up then Down (or Down then Up) within 0.5s = open menu
// Uses UIAlertController like the original tweak
//

#define VCAM_DIR   @"/var/mobile/Library/Caches/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"

// ============================================================
// Forward declarations
// ============================================================
static void vcam_showMenu(void);

// ============================================================
// Global state
// ============================================================
static NSLock                    *gLock    = nil;
static AVAssetReader             *gReader  = nil;
static AVAssetReaderTrackOutput  *gOutput  = nil;
static NSMutableSet              *gProxies = nil;

// Volume detection
static NSTimeInterval gLastUpTime   = 0;
static NSTimeInterval gLastDownTime = 0;

// ============================================================
// Helpers
// ============================================================
static BOOL vcam_flagExists(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:VCAM_FLAG];
}

static BOOL vcam_videoExists(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:VCAM_VIDEO];
}

static BOOL vcam_isEnabled(void) {
    return vcam_flagExists() && vcam_videoExists();
}

// ============================================================
// Video reader
// ============================================================
static BOOL vcam_openReader(void) {
    gReader = nil;
    gOutput = nil;

    NSURL *url = [NSURL fileURLWithPath:VCAM_VIDEO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return NO;

    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!reader || err) return NO;

    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:settings];
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) return NO;

    gReader = reader;
    gOutput = output;
    return YES;
}

static CMSampleBufferRef vcam_nextFrame(CMSampleBufferRef original) {
    if (!vcam_isEnabled()) return NULL;

    [gLock lock];
    if (!gReader) vcam_openReader();

    CMSampleBufferRef frame = nil;
    if (gReader) {
        frame = [gOutput copyNextSampleBuffer];
        if (!frame || gReader.status != AVAssetReaderStatusReading) {
            gReader = nil;
            gOutput = nil;
            if (vcam_openReader())
                frame = [gOutput copyNextSampleBuffer];
        }
    }
    [gLock unlock];

    if (!frame) return NULL;

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
    return timedFrame;
}

// ============================================================
// Proxy delegate
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
        [real captureOutput:output didOutputSampleBuffer:replaced fromConnection:connection];
        CFRelease(replaced);
    } else {
        [real captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id real = self.realDelegate;
    if ([real respondsToSelector:_cmd])
        [real captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.realDelegate respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    if ([self.realDelegate respondsToSelector:sel]) return self.realDelegate;
    return [super forwardingTargetForSelector:sel];
}

@end

// ============================================================
// Volume observer - uses KVO on AVAudioSession outputVolume
// ============================================================
@interface VCamVolumeObserver : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
+ (instancetype)shared;
@end

@implementation VCamVolumeObserver

+ (instancetype)shared {
    static VCamVolumeObserver *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCamVolumeObserver alloc] init]; });
    return inst;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (![keyPath isEqualToString:@"outputVolume"]) return;

    float oldVol = [change[NSKeyValueChangeOldKey] floatValue];
    float newVol = [change[NSKeyValueChangeNewKey] floatValue];
    if (oldVol == newVol) return;

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();

    if (newVol > oldVol) {
        gLastUpTime = now;
    } else {
        gLastDownTime = now;
    }

    if (gLastUpTime > 0 && gLastDownTime > 0 &&
        fabs(gLastUpTime - gLastDownTime) < 0.5) {
        gLastUpTime = 0;
        gLastDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            vcam_showMenu();
        });
    }
}

// UIImagePickerControllerDelegate
- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

// UIDocumentPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)ctrl
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL sec = [url startAccessingSecurityScopedResource];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    if (sec) [url stopAccessingSecurityScopedResource];
    [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)ctrl {}

@end

// ============================================================
// Menu UI - UIAlertController (same style as original tweak)
// ============================================================
static UIViewController *vcam_topVC(void) {
    UIWindow *window = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
    }
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void vcam_showMenu(void) {
    UIViewController *topVC = vcam_topVC();
    if (!topVC) return;
    // Don't show if already presenting an alert
    if ([topVC isKindOfClass:[UIAlertController class]]) return;

    NSString *status;
    if (vcam_isEnabled()) {
        status = @"Status: ON";
    } else if (vcam_videoExists()) {
        status = @"Status: OFF";
    } else {
        status = @"Status: No video";
    }

    NSString *msg = [NSString stringWithFormat:
        @"Volume+ then Volume- = Open menu\n"
        @"Select a video to use as camera.\n"
        @"Aspect ratio 4:3 or 16:9 recommended.\n\n"
        @"%@", status];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"VCam Plus"
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];

    // Select from Photos
    [alert addAction:[UIAlertAction
        actionWithTitle:@"Select from Photos"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = [VCamVolumeObserver shared];
        [vcam_topVC() presentViewController:picker animated:YES completion:nil];
    }]];

    // Select from Files
    [alert addAction:[UIAlertAction
        actionWithTitle:@"Select from Files"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.movie"]
                                                                  inMode:UIDocumentPickerModeImport];
        picker.delegate = [VCamVolumeObserver shared];
        [vcam_topVC() presentViewController:picker animated:YES completion:nil];
    }]];

    // Enable / Disable toggle
    if (vcam_flagExists()) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"Disable Camera Replace"
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *a) {
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
            [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
        }]];
    } else {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"Enable Camera Replace"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }]];
    }

    // Cancel
    [alert addAction:[UIAlertAction
        actionWithTitle:@"Cancel"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================
// Hooks
// ============================================================
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:[VCamProxyDelegate class]]) {
        VCamProxyDelegate *proxy = [VCamProxyDelegate new];
        proxy.realDelegate = delegate;
        [gProxies addObject:proxy];
        %orig(proxy, queue);
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
        gLock    = [[NSLock alloc] init];
        gProxies = [NSMutableSet new];

        [[NSFileManager defaultManager]
            createDirectoryAtPath:VCAM_DIR
          withIntermediateDirectories:YES
                         attributes:nil
                               error:nil];

        // Volume detection + menu only in UIKit apps (not WebContent)
        if ([UIApplication sharedApplication]) {
            // Use KVO on AVAudioSession outputVolume - reliable on iOS 16
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryAmbient
                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                           error:nil];
            [session setActive:YES error:nil];
            [session addObserver:[VCamVolumeObserver shared]
                      forKeyPath:@"outputVolume"
                         options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                         context:nil];
        }
    }
}
