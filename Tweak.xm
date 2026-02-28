// ============================================================
// VCam Plus v5 — Hook SBVolumeControl (SpringBoard private class)
// Architecture:
//   SpringBoard process: hook volume buttons → show UI
//   Camera app processes: hook AVCaptureVideoDataOutput → replace frames
// ============================================================
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#define VCAM_DIR   @"/var/mobile/Library/Caches/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"

// ============================================================
// Forward declarations
// ============================================================
static void vcam_showMenu(void);

// ============================================================
// Globals
// ============================================================
static NSLock                    *gLock    = nil;
static AVAssetReader             *gReader  = nil;
static AVAssetReaderTrackOutput  *gOutput  = nil;
static NSMutableSet              *gProxies = nil;

// Volume combo detection (SpringBoard only)
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

    if (!vcam_videoExists()) return NO;

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
    if (!gReader || gReader.status != AVAssetReaderStatusReading)
        vcam_openReader();

    CMSampleBufferRef frame = nil;
    if (gReader) {
        frame = [gOutput copyNextSampleBuffer];
        if (!frame) {
            // Loop: reopen
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

    return (st == noErr) ? timedFrame : NULL;
}

// ============================================================
// Proxy delegate (camera apps)
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
// UI Helper (SpringBoard — file picker delegate)
// ============================================================
@interface VCamUIHelper : NSObject
    <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
+ (instancetype)shared;
@end

@implementation VCamUIHelper

+ (instancetype)shared {
    static VCamUIHelper *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCamUIHelper alloc] init]; });
    return inst;
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    // Enable automatically after selecting video
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)ctrl
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL sec = [url startAccessingSecurityScopedResource];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    if (sec) [url stopAccessingSecurityScopedResource];
    // Enable automatically after selecting video
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)ctrl {}

@end

// ============================================================
// Menu (SpringBoard — UIAlertController)
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

    BOOL enabled = vcam_flagExists();
    BOOL hasVideo = vcam_videoExists();

    NSString *status;
    if (enabled && hasVideo)
        status = @"状态: 已开启";
    else if (hasVideo)
        status = @"状态: 已关闭 (视频已选择)";
    else
        status = @"状态: 未选择视频";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"VCam Plus"
                         message:status
                  preferredStyle:UIAlertControllerStyleAlert];

    // Select from Photos
    [alert addAction:[UIAlertAction
        actionWithTitle:@"从相册选择视频"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC();
            if (!vc) return;
            UIImagePickerController *picker = [[UIImagePickerController alloc] init];
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            picker.mediaTypes = @[@"public.movie"];
            picker.delegate = [VCamUIHelper shared];
            [vc presentViewController:picker animated:YES completion:nil];
        });
    }]];

    // Select from Files
    [alert addAction:[UIAlertAction
        actionWithTitle:@"从文件选择视频"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC();
            if (!vc) return;
            UIDocumentPickerViewController *picker =
                [[UIDocumentPickerViewController alloc]
                    initWithDocumentTypes:@[@"public.movie", @"public.video"]
                                  inMode:UIDocumentPickerModeImport];
            picker.delegate = [VCamUIHelper shared];
            [vc presentViewController:picker animated:YES completion:nil];
        });
    }]];

    // Toggle enable/disable
    if (enabled) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"关闭虚拟摄像头"
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *a) {
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
            [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
        }]];
    } else if (hasVideo) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"开启虚拟摄像头"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }]];
    }

    [alert addAction:[UIAlertAction
        actionWithTitle:@"取消"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================
// SpringBoard hooks — SBVolumeControl (volume button detection)
// ============================================================
%group SBHooks

%hook SBVolumeControl

- (void)increaseVolume {
    %orig;
    NSTimeInterval now = CACurrentMediaTime();
    gLastUpTime = now;
    if (gLastDownTime > 0 && (now - gLastDownTime) < 1.5) {
        gLastUpTime = 0;
        gLastDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            vcam_showMenu();
        });
    }
}

- (void)decreaseVolume {
    %orig;
    NSTimeInterval now = CACurrentMediaTime();
    gLastDownTime = now;
    if (gLastUpTime > 0 && (now - gLastUpTime) < 1.5) {
        gLastUpTime = 0;
        gLastDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            vcam_showMenu();
        });
    }
}

%end

%end

// ============================================================
// Camera hooks — frame replacement (all UIKit processes)
// ============================================================
%group CamHooks

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:[VCamProxyDelegate class]]) {
        VCamProxyDelegate *proxy = [VCamProxyDelegate new];
        proxy.realDelegate = delegate;
        @synchronized(gProxies) {
            [gProxies addObject:proxy];
        }
        %orig(proxy, queue);
    } else {
        %orig;
    }
}

%end

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

        // Always init camera hooks (works in all UIKit processes)
        %init(CamHooks);

        // Init SpringBoard hooks only if SBVolumeControl exists
        Class sbvc = NSClassFromString(@"SBVolumeControl");
        if (sbvc) {
            %init(SBHooks);
        }
    }
}
