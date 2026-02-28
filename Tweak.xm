// ============================================================
// VCam Plus v5.1 — with diagnostics
// Architecture:
//   SpringBoard: hook SBVolumeControl → show UI
//   Camera apps: hook AVCaptureVideoDataOutput → replace frames
// ============================================================
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#define VCAM_DIR   @"/var/tmp/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"
#define VCAM_LOG   @"/var/tmp/vcam_debug.log"

// ============================================================
// Forward declarations
// ============================================================
static void vcam_showMenu(void);

// ============================================================
// Debug logging
// ============================================================
static void vcam_log(NSString *msg) {
    NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                 dateStyle:NSDateFormatterNoStyle
                                                 timeStyle:NSDateFormatterMediumStyle];
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *line = [NSString stringWithFormat:@"[%@] %@: %@\n", ts, proc, msg];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:VCAM_LOG]) {
        [fm createFileAtPath:VCAM_LOG contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:VCAM_LOG];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

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

// Debug counters
static int gHookCount = 0;
static int gFrameCount = 0;
static int gReplaceCount = 0;

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

    if (!vcam_videoExists()) {
        vcam_log(@"openReader: video file not found");
        return NO;
    }

    NSURL *url = [NSURL fileURLWithPath:VCAM_VIDEO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
        vcam_log(@"openReader: no video tracks found");
        return NO;
    }

    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!reader || err) {
        vcam_log([NSString stringWithFormat:@"openReader: AVAssetReader error: %@", err]);
        return NO;
    }

    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:settings];
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        vcam_log(@"openReader: canAddOutput failed");
        return NO;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        vcam_log([NSString stringWithFormat:@"openReader: startReading failed: %@", reader.error]);
        return NO;
    }

    gReader = reader;
    gOutput = output;
    vcam_log(@"openReader: SUCCESS");
    return YES;
}

static CMSampleBufferRef vcam_nextFrame(CMSampleBufferRef original) {
    gFrameCount++;
    if (!vcam_isEnabled()) return NULL;

    [gLock lock];
    if (!gReader || gReader.status != AVAssetReaderStatusReading)
        vcam_openReader();

    CMSampleBufferRef frame = nil;
    if (gReader) {
        frame = [gOutput copyNextSampleBuffer];
        if (!frame) {
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

    if (st == noErr && timedFrame) {
        gReplaceCount++;
        if (gReplaceCount == 1) {
            vcam_log(@"First frame replaced successfully!");
        }
        return timedFrame;
    }
    return NULL;
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
    vcam_log([NSString stringWithFormat:@"imagePickerDone: url=%@", url]);
    if (!url) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    NSError *err = nil;
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:&err];
    vcam_log([NSString stringWithFormat:@"copyVideo: err=%@", err]);
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    vcam_log([NSString stringWithFormat:@"flagExists=%d videoExists=%d",
              vcam_flagExists(), vcam_videoExists()]);
    [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)ctrl
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    vcam_log([NSString stringWithFormat:@"docPickerDone: url=%@", url]);
    if (!url) return;
    BOOL sec = [url startAccessingSecurityScopedResource];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    NSError *err = nil;
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:&err];
    if (sec) [url stopAccessingSecurityScopedResource];
    vcam_log([NSString stringWithFormat:@"copyVideo: err=%@", err]);
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

    // Get video file size
    NSString *videoInfo = @"无";
    if (hasVideo) {
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:VCAM_VIDEO error:nil];
        long long sz = [attrs fileSize];
        videoInfo = [NSString stringWithFormat:@"%.1f MB", sz / 1048576.0];
    }

    NSString *status = [NSString stringWithFormat:
        @"开关: %@\n视频: %@\n路径: %@",
        enabled ? @"已开启" : @"已关闭",
        videoInfo,
        VCAM_VIDEO];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"VCam Plus v5.1"
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
            vcam_log(@"User disabled vcam");
        }]];
    } else {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"开启虚拟摄像头"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            vcam_log([NSString stringWithFormat:@"User enabled vcam, flagExists=%d", vcam_flagExists()]);
        }]];
    }

    // Diagnostics
    [alert addAction:[UIAlertAction
        actionWithTitle:@"查看诊断日志"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *log = [NSString stringWithContentsOfFile:VCAM_LOG
                                                     encoding:NSUTF8StringEncoding error:nil];
            if (!log || log.length == 0) log = @"(日志为空 - 没有任何进程加载过插件)";
            // Show last 2000 chars
            if (log.length > 2000)
                log = [log substringFromIndex:log.length - 2000];

            UIAlertController *logAlert = [UIAlertController
                alertControllerWithTitle:@"诊断日志"
                                 message:log
                          preferredStyle:UIAlertControllerStyleAlert];
            [logAlert addAction:[UIAlertAction actionWithTitle:@"清除日志"
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *a2) {
                    [@"" writeToFile:VCAM_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }]];
            [logAlert addAction:[UIAlertAction actionWithTitle:@"关闭"
                style:UIAlertActionStyleCancel handler:nil]];
            [vcam_topVC() presentViewController:logAlert animated:YES completion:nil];
        });
    }]];

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
        gHookCount++;
        vcam_log([NSString stringWithFormat:@"HOOK setSampleBufferDelegate #%d, delegate=%@",
                  gHookCount, NSStringFromClass([delegate class])]);
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

        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
        vcam_log([NSString stringWithFormat:@"LOADED in %@ (%@)", proc, bid]);

        // Always init camera hooks
        %init(CamHooks);
        vcam_log(@"CamHooks initialized");

        // Init SpringBoard hooks only if SBVolumeControl exists
        Class sbvc = NSClassFromString(@"SBVolumeControl");
        if (sbvc) {
            %init(SBHooks);
            vcam_log(@"SBHooks initialized (SpringBoard)");
        }
    }
}
