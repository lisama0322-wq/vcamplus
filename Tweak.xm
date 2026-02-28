#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

#define VCAM_DIR   @"/var/mobile/Library/Caches/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"

// ============================================================
// Forward declarations
// ============================================================
static void vcam_showMenu(void);
static void vcam_setupVolumeMonitor(void);

// ============================================================
// Global state
// ============================================================
static NSLock                    *gLock    = nil;
static AVAssetReader             *gReader  = nil;
static AVAssetReaderTrackOutput  *gOutput  = nil;
static NSMutableSet              *gProxies = nil;

// Volume detection
static UISlider      *gVolSlider     = nil;
static float          gPrevVol       = -1;
static NSTimeInterval gLastUpTime    = 0;
static NSTimeInterval gLastDownTime  = 0;
static BOOL           gVolumeSetup   = NO;

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
// Volume & Menu helper
// ============================================================
@interface VCamHelper : NSObject
    <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
+ (instancetype)shared;
- (void)volumeChanged;
@end

@implementation VCamHelper

+ (instancetype)shared {
    static VCamHelper *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCamHelper alloc] init]; });
    return inst;
}

- (void)volumeChanged {
    if (!gVolSlider) return;
    float newVol = gVolSlider.value;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();

    if (gPrevVol >= 0 && newVol != gPrevVol) {
        if (newVol > gPrevVol) {
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
    gPrevVol = newVol;
}

// Also listen for private notification as fallback
- (void)systemVolumeChanged:(NSNotification *)note {
    NSString *reason = note.userInfo[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];
    if (![reason isEqualToString:@"ExplicitVolumeChange"]) return;

    float newVol = [note.userInfo[@"AVSystemController_AudioVolumeNotificationParameter"] floatValue];
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();

    if (gPrevVol >= 0 && newVol != gPrevVol) {
        if (newVol > gPrevVol) {
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
    gPrevVol = newVol;
}

// KVO fallback
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (![keyPath isEqualToString:@"outputVolume"]) return;
    float oldVol = [change[NSKeyValueChangeOldKey] floatValue];
    float newVol = [change[NSKeyValueChangeNewKey] floatValue];
    if (oldVol == newVol) return;

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (newVol > oldVol) gLastUpTime = now;
    else gLastDownTime = now;

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
// Menu - UIAlertController
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
    if (!window) return nil;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void vcam_showMenu(void) {
    UIViewController *topVC = vcam_topVC();
    if (!topVC) return;
    if ([topVC isKindOfClass:[UIAlertController class]]) return;

    NSString *status;
    if (vcam_isEnabled())
        status = @"[ON] Camera replaced";
    else if (vcam_videoExists())
        status = @"[OFF] Ready";
    else
        status = @"[No video selected]";

    NSString *msg = [NSString stringWithFormat:
        @"Volume+ then Volume- to open menu\n"
        @"Video ratio 4:3 or 16:9 recommended\n\n"
        @"Status: %@", status];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"VCam Plus"
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Select from Photos"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = [VCamHelper shared];
        [vcam_topVC() presentViewController:picker animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Select from Files"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.movie"]
                                                                  inMode:UIDocumentPickerModeImport];
        picker.delegate = [VCamHelper shared];
        [vcam_topVC() presentViewController:picker animated:YES completion:nil];
    }]];

    if (vcam_flagExists()) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"Disable Replace"
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *a) {
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
            [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
        }]];
    } else {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"Enable Replace"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }]];
    }

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Cancel"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================
// Volume monitor setup - 3 methods combined for reliability
// ============================================================
static void vcam_setupVolumeMonitor(void) {
    if (gVolumeSetup) return;
    gVolumeSetup = YES;

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
    if (!window) { gVolumeSetup = NO; return; }

    // Method 1: Hidden MPVolumeView slider (most reliable)
    MPVolumeView *volView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 0, 0)];
    volView.alpha = 0.01;
    [window addSubview:volView];

    for (UIView *view in volView.subviews) {
        if ([view isKindOfClass:[UISlider class]]) {
            gVolSlider = (UISlider *)view;
            gPrevVol = gVolSlider.value;
            [gVolSlider addTarget:[VCamHelper shared]
                           action:@selector(volumeChanged)
                 forControlEvents:UIControlEventValueChanged];
            break;
        }
    }

    // Method 2: Private notification (fallback)
    [[NSNotificationCenter defaultCenter]
        addObserver:[VCamHelper shared]
           selector:@selector(systemVolumeChanged:)
               name:@"AVSystemController_SystemVolumeDidChangeNotification"
             object:nil];

    // Method 3: KVO on AVAudioSession (secondary fallback)
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (gPrevVol < 0) gPrevVol = session.outputVolume;
    @try {
        [session addObserver:[VCamHelper shared]
                  forKeyPath:@"outputVolume"
                     options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                     context:nil];
    } @catch (NSException *e) {}
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

        // Volume detection only in UIKit apps
        if ([UIApplication sharedApplication]) {
            // Wait for app to become active, then set up volume monitor
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            vcam_setupVolumeMonitor();
                        }];

            // Also try after a short delay (for SpringBoard)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    vcam_setupVolumeMonitor();
                });
        }
    }
}
