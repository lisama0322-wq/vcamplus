// ============================================================
// VCam Plus v5.3 — Direct frame rendering (no AVPlayer)
// ============================================================
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define VCAM_DIR   @"/var/tmp/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"
#define VCAM_LOG   @"/var/tmp/vcam_debug.log"

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
    if (![fm fileExistsAtPath:VCAM_LOG])
        [fm createFileAtPath:VCAM_LOG contents:nil attributes:nil];
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

static NSTimeInterval gLastUpTime   = 0;
static NSTimeInterval gLastDownTime = 0;

static Class gPreviewLayerClass = nil;

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
// Video reader (shared by overlay + data output proxy)
// ============================================================
static BOOL vcam_openReader(void) {
    gReader = nil; gOutput = nil;
    if (!vcam_videoExists()) return NO;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:VCAM_VIDEO]
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

    gReader = reader; gOutput = output;
    return YES;
}

// Read next frame as CMSampleBuffer (for data output proxy)
static CMSampleBufferRef vcam_nextFrame(CMSampleBufferRef original) {
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
    return (st == noErr) ? timedFrame : NULL;
}

// Read next frame as CGImage (for preview overlay)
static CGImageRef vcam_nextCGImage(void) {
    [gLock lock];
    if (!gReader || gReader.status != AVAssetReaderStatusReading)
        vcam_openReader();

    CMSampleBufferRef buf = nil;
    if (gReader) {
        buf = [gOutput copyNextSampleBuffer];
        if (!buf) {
            if (vcam_openReader())
                buf = [gOutput copyNextSampleBuffer];
        }
    }
    [gLock unlock];
    if (!buf) return NULL;

    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(buf);
    if (!pixelBuffer) { CFRelease(buf); return NULL; }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    size_t width      = CVPixelBufferGetWidth(pixelBuffer);
    size_t height     = CVPixelBufferGetHeight(pixelBuffer);
    size_t bpr        = CVPixelBufferGetBytesPerRow(pixelBuffer);
    void  *base       = CVPixelBufferGetBaseAddress(pixelBuffer);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx   = CGBitmapContextCreate(base, width, height, 8, bpr, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef img     = CGBitmapContextCreateImage(ctx);

    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    CFRelease(buf);

    return img; // caller must CGImageRelease
}

// ============================================================
// Overlay controller — renders video frames via timer
// ============================================================
@interface VCamOverlay : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, weak)   CALayer *previewLayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) int frameCount;
+ (void)attachToPreviewLayer:(CALayer *)previewLayer;
+ (void)removeAll;
@end

static NSMutableArray *gOverlays = nil;

@implementation VCamOverlay

+ (void)attachToPreviewLayer:(CALayer *)previewLayer {
    // Already has overlay?
    static char kKey;
    if (objc_getAssociatedObject(previewLayer, &kKey)) return;
    if (!vcam_isEnabled()) return;

    VCamOverlay *ctrl = [[VCamOverlay alloc] init];
    ctrl.previewLayer = previewLayer;

    // Create overlay layer
    CALayer *overlay = [CALayer layer];
    overlay.frame = previewLayer.bounds;
    overlay.contentsGravity = kCAGravityResizeAspectFill;
    overlay.masksToBounds = YES;
    overlay.backgroundColor = [UIColor blackColor].CGColor; // Black until first frame
    ctrl.layer = overlay;

    // Add above preview layer
    CALayer *parent = previewLayer.superlayer;
    if (parent) {
        [parent insertSublayer:overlay above:previewLayer];
    } else {
        [previewLayer addSublayer:overlay];
    }

    // Start frame timer at ~30fps
    ctrl.timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
        [ctrl renderNextFrame];
    }];

    objc_setAssociatedObject(previewLayer, &kKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized(gOverlays) { [gOverlays addObject:ctrl]; }

    vcam_log([NSString stringWithFormat:@"Overlay attached, frame=%@, parent=%@",
              NSStringFromCGRect(previewLayer.bounds),
              parent ? @"YES" : @"NO"]);
}

- (void)renderNextFrame {
    if (!vcam_isEnabled()) {
        self.layer.hidden = YES;
        return;
    }
    self.layer.hidden = NO;

    // Keep frame in sync with preview layer
    CALayer *pl = self.previewLayer;
    if (pl && !CGRectEqualToRect(self.layer.frame, pl.bounds)) {
        self.layer.frame = pl.bounds;
    }

    CGImageRef img = vcam_nextCGImage();
    if (img) {
        self.layer.contents = (__bridge id)img;
        CGImageRelease(img);
        self.frameCount++;
        if (self.frameCount == 1) {
            vcam_log(@"First overlay frame rendered!");
        }
    }
}

+ (void)removeAll {
    @synchronized(gOverlays) {
        for (VCamOverlay *ctrl in gOverlays) {
            [ctrl.timer invalidate];
            [ctrl.layer removeFromSuperlayer];
        }
        [gOverlays removeAllObjects];
    }
}

- (void)dealloc {
    [_timer invalidate];
}

@end

// ============================================================
// Proxy delegate (for video calling apps)
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
// UI Helper
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
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    vcam_log([NSString stringWithFormat:@"Video selected, flag=%d video=%d",
              vcam_flagExists(), vcam_videoExists()]);
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
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)ctrl {}
@end

// ============================================================
// Menu
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
    NSString *videoInfo = @"无";
    if (hasVideo) {
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:VCAM_VIDEO error:nil];
        videoInfo = [NSString stringWithFormat:@"%.1f MB", [attrs fileSize] / 1048576.0];
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"VCam Plus v5.3"
                         message:[NSString stringWithFormat:@"开关: %@\n视频: %@",
                                  enabled ? @"已开启" : @"已关闭", videoInfo]
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"从相册选择视频"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC(); if (!vc) return;
            UIImagePickerController *p = [[UIImagePickerController alloc] init];
            p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            p.mediaTypes = @[@"public.movie"];
            p.delegate = [VCamUIHelper shared];
            [vc presentViewController:p animated:YES completion:nil];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"从文件选择视频"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC(); if (!vc) return;
            UIDocumentPickerViewController *p =
                [[UIDocumentPickerViewController alloc]
                    initWithDocumentTypes:@[@"public.movie", @"public.video"]
                                  inMode:UIDocumentPickerModeImport];
            p.delegate = [VCamUIHelper shared];
            [vc presentViewController:p animated:YES completion:nil];
        });
    }]];

    if (enabled) {
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭虚拟摄像头"
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
            [gLock lock]; gReader = nil; gOutput = nil; [gLock unlock];
        }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"开启虚拟摄像头"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"查看诊断日志"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *log = [NSString stringWithContentsOfFile:VCAM_LOG
                                                     encoding:NSUTF8StringEncoding error:nil];
            if (!log || log.length == 0) log = @"(空)";
            if (log.length > 2000) log = [log substringFromIndex:log.length - 2000];
            UIAlertController *la = [UIAlertController alertControllerWithTitle:@"诊断日志"
                message:log preferredStyle:UIAlertControllerStyleAlert];
            [la addAction:[UIAlertAction actionWithTitle:@"清除"
                style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a2) {
                [@"" writeToFile:VCAM_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }]];
            [la addAction:[UIAlertAction actionWithTitle:@"关闭"
                style:UIAlertActionStyleCancel handler:nil]];
            [vcam_topVC() presentViewController:la animated:YES completion:nil];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];

    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================
// SpringBoard hooks
// ============================================================
%group SBHooks
%hook SBVolumeControl
- (void)increaseVolume {
    %orig;
    NSTimeInterval now = CACurrentMediaTime();
    gLastUpTime = now;
    if (gLastDownTime > 0 && (now - gLastDownTime) < 1.5) {
        gLastUpTime = 0; gLastDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{ vcam_showMenu(); });
    }
}
- (void)decreaseVolume {
    %orig;
    NSTimeInterval now = CACurrentMediaTime();
    gLastDownTime = now;
    if (gLastUpTime > 0 && (now - gLastUpTime) < 1.5) {
        gLastUpTime = 0; gLastDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{ vcam_showMenu(); });
    }
}
%end
%end

// ============================================================
// Camera hooks
// ============================================================
%group CamHooks

// Hook 1: Preview layer overlay (direct frame rendering)
%hook CALayer
- (void)addSublayer:(CALayer *)layer {
    %orig;
    if (gPreviewLayerClass && [layer isKindOfClass:gPreviewLayerClass]) {
        vcam_log(@"PreviewLayer detected!");
        // Attach overlay synchronously
        [VCamOverlay attachToPreviewLayer:layer];
    }
}
%end

// Hook 2: Data output delegate (for video calling apps)
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:[VCamProxyDelegate class]]) {
        vcam_log([NSString stringWithFormat:@"HOOK setSampleBufferDelegate: %@",
                  NSStringFromClass([delegate class])]);
        VCamProxyDelegate *proxy = [VCamProxyDelegate new];
        proxy.realDelegate = delegate;
        @synchronized(gProxies) { [gProxies addObject:proxy]; }
        %orig(proxy, queue);
    } else {
        %orig;
    }
}
%end

// Hook 3: Session tracking
%hook AVCaptureSession
- (void)startRunning {
    %orig;
    vcam_log(@"AVCaptureSession startRunning");
}
%end

%end

// ============================================================
// Constructor
// ============================================================
%ctor {
    @autoreleasepool {
        gLock     = [[NSLock alloc] init];
        gProxies  = [NSMutableSet new];
        gOverlays = [NSMutableArray new];

        [[NSFileManager defaultManager]
            createDirectoryAtPath:VCAM_DIR
          withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
        vcam_log([NSString stringWithFormat:@"LOADED in %@ (%@)", proc, bid]);

        gPreviewLayerClass = NSClassFromString(@"AVCaptureVideoPreviewLayer");

        %init(CamHooks);
        vcam_log(@"CamHooks initialized");

        Class sbvc = NSClassFromString(@"SBVolumeControl");
        if (sbvc) {
            %init(SBHooks);
            vcam_log(@"SBHooks initialized");
        }
    }
}
