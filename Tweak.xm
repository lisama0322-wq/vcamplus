// VCam Plus v6.0 — Delegate Proxy (no third-party class modification)
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define VCAM_DIR   @"/var/jb/var/mobile/Library/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"
#define VCAM_LOG   VCAM_DIR @"/debug.log"
static void vcam_showMenu(void);

// --- Logging ---
static void vcam_log(NSString *msg) {
    @try {
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *line = [NSString stringWithFormat:@"[%@] %@: %@\n", ts, proc, msg];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:VCAM_LOG])
            [fm createFileAtPath:VCAM_LOG contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:VCAM_LOG];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

// --- Globals ---
static NSLock *gLockA = nil, *gLockB = nil;
static AVAssetReader *gReaderA = nil, *gReaderB = nil;
static AVAssetReaderTrackOutput *gOutputA = nil, *gOutputB = nil;
static NSTimeInterval gLastUpTime = 0, gLastDownTime = 0;
static Class gPreviewLayerClass = nil;
static char kOverlayKey;
static char kProxyKey;

// --- Helpers ---
static BOOL vcam_flagExists(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:VCAM_FLAG];
}
static BOOL vcam_videoExists(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:VCAM_VIDEO];
}
static BOOL vcam_isEnabled(void) {
    return vcam_flagExists() && vcam_videoExists();
}

// --- Video reader ---
static BOOL vcam_openReaderInto(AVAssetReader *__strong *rdr, AVAssetReaderTrackOutput *__strong *out) {
    @try {
        *rdr = nil; *out = nil;
        if (!vcam_videoExists()) return NO;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:VCAM_VIDEO]
                             options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) return NO;
        NSError *err = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
        if (!reader || err) return NO;
        NSDictionary *settings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:settings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) return NO;
        [reader addOutput:output];
        if (![reader startReading]) return NO;
        *rdr = reader; *out = output;
        return YES;
    } @catch (NSException *e) { return NO; }
}

static CMSampleBufferRef vcam_readFrame(NSLock *lock, AVAssetReader *__strong *rdr, AVAssetReaderTrackOutput *__strong *out) {
    [lock lock];
    @try {
        if (!*rdr || (*rdr).status != AVAssetReaderStatusReading)
            vcam_openReaderInto(rdr, out);
        CMSampleBufferRef frame = nil;
        if (*rdr) {
            frame = [*out copyNextSampleBuffer];
            if (!frame) {
                if (vcam_openReaderInto(rdr, out))
                    frame = [*out copyNextSampleBuffer];
            }
        }
        [lock unlock];
        return frame;
    } @catch (NSException *e) { [lock unlock]; return NULL; }
}

// --- Replacement buffer (Reader A) ---
static CMSampleBufferRef vcam_nextReplacementBuffer(CMSampleBufferRef originalBuffer) {
    if (!vcam_isEnabled()) return NULL;
    CMSampleBufferRef frame = vcam_readFrame(gLockA, &gReaderA, &gOutputA);
    if (!frame) return NULL;
    @try {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(frame);
        if (!pixelBuffer) { CFRelease(frame); return NULL; }
        CMVideoFormatDescriptionRef formatDesc = NULL;
        OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
        if (st != noErr || !formatDesc) { CFRelease(frame); return NULL; }
        CMSampleTimingInfo timing;
        timing.duration = CMSampleBufferGetDuration(originalBuffer);
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originalBuffer);
        timing.decodeTimeStamp = kCMTimeInvalid;
        CMSampleBufferRef newBuffer = NULL;
        st = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, formatDesc, &timing, &newBuffer);
        CFRelease(formatDesc);
        CFRelease(frame);
        return (st == noErr) ? newBuffer : NULL;
    } @catch (NSException *e) { CFRelease(frame); return NULL; }
}

// --- CGImage for overlay (Reader B) ---
static CGImageRef vcam_nextCGImage(void) {
    if (!vcam_isEnabled()) return NULL;
    CMSampleBufferRef buf = vcam_readFrame(gLockB, &gReaderB, &gOutputB);
    if (!buf) return NULL;
    @try {
        CVImageBufferRef pxb = CMSampleBufferGetImageBuffer(buf);
        if (!pxb) { CFRelease(buf); return NULL; }
        CVPixelBufferLockBaseAddress(pxb, kCVPixelBufferLock_ReadOnly);
        size_t w = CVPixelBufferGetWidth(pxb), h = CVPixelBufferGetHeight(pxb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pxb);
        void *base = CVPixelBufferGetBaseAddress(pxb);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx); CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(pxb, kCVPixelBufferLock_ReadOnly);
        CFRelease(buf);
        return img;
    } @catch (NSException *e) { CFRelease(buf); return NULL; }
}

// ============================================================
// Delegate Proxy — core of v6.0
// Instead of hooking third-party delegate classes with MSHookMessageEx,
// we wrap the real delegate in our own proxy object.
// This avoids modifying ANY third-party class at runtime.
// ============================================================
@interface VCamDelegateProxy : NSObject
@property (nonatomic, strong) id realDelegate;
@end

@implementation VCamDelegateProxy

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @try {
        if (vcam_isEnabled()) {
            CMSampleBufferRef replaced = vcam_nextReplacementBuffer(sampleBuffer);
            if (replaced) {
                [self.realDelegate captureOutput:output didOutputSampleBuffer:replaced fromConnection:connection];
                CFRelease(replaced);
                return;
            }
        }
        [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    } @catch (NSException *e) {}
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @try {
        if ([self.realDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)])
            [self.realDelegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    } @catch (NSException *e) {}
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    if (aSelector == @selector(captureOutput:didDropSampleBuffer:fromConnection:))
        return [self.realDelegate respondsToSelector:aSelector];
    return [super respondsToSelector:aSelector] || [self.realDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.realDelegate;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
    if (!sig) sig = [self.realDelegate methodSignatureForSelector:aSelector];
    return sig;
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if ([self.realDelegate respondsToSelector:invocation.selector])
        [invocation invokeWithTarget:self.realDelegate];
}

@end

// --- Overlay ---
@interface VCamOverlay : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, weak) CALayer *previewLayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) int failCount;
+ (void)attachToPreviewLayer:(CALayer *)pl;
@end
static NSMutableArray *gOverlays = nil;

@implementation VCamOverlay
+ (void)attachToPreviewLayer:(CALayer *)previewLayer {
    @try {
        if (!vcam_isEnabled()) return;
        VCamOverlay *existing = objc_getAssociatedObject(previewLayer, &kOverlayKey);
        if (existing) {
            if (existing.layer.superlayer) return;
            [existing.timer invalidate]; [existing.layer removeFromSuperlayer];
            @synchronized(gOverlays) { [gOverlays removeObject:existing]; }
            objc_setAssociatedObject(previewLayer, &kOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        VCamOverlay *ctrl = [[VCamOverlay alloc] init];
        ctrl.previewLayer = previewLayer;
        CALayer *overlay = [CALayer layer];
        overlay.frame = previewLayer.bounds;
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.masksToBounds = YES; overlay.hidden = YES;
        ctrl.layer = overlay;
        CALayer *parent = previewLayer.superlayer;
        if (parent) [parent insertSublayer:overlay above:previewLayer];
        else [previewLayer addSublayer:overlay];
        ctrl.timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *t) {
            @try { [ctrl renderNextFrame]; } @catch (NSException *e) {}
        }];
        objc_setAssociatedObject(previewLayer, &kOverlayKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized(gOverlays) { [gOverlays addObject:ctrl]; }
        vcam_log(@"Overlay attached");
    } @catch (NSException *e) {}
}
- (void)renderNextFrame {
    if (!vcam_isEnabled()) { self.layer.hidden = YES; return; }
    CALayer *pl = self.previewLayer; if (!pl) return;
    if (!self.layer.superlayer) {
        CALayer *p = pl.superlayer;
        if (p) { @try { [p insertSublayer:self.layer above:pl]; } @catch (NSException *e) { return; } }
        else return;
    }
    if (!CGRectEqualToRect(self.layer.frame, pl.bounds) && pl.bounds.size.width > 0)
        self.layer.frame = pl.bounds;
    CGImageRef img = vcam_nextCGImage();
    if (img) {
        self.layer.contents = (__bridge id)img; CGImageRelease(img);
        self.layer.hidden = NO; self.failCount = 0;
    } else { self.failCount++; if (self.failCount > 60) self.layer.hidden = YES; }
}
- (void)dealloc { [_timer invalidate]; }
@end

// --- UI Helper ---
@interface VCamUIHelper : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
+ (instancetype)shared;
@end
@implementation VCamUIHelper
+ (instancetype)shared {
    static VCamUIHelper *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCamUIHelper alloc] init]; }); return inst;
}
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = info[UIImagePickerControllerMediaURL]; if (!url) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    vcam_log(@"Video selected from Photos");
    [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
    [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)ctrl didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject; if (!url) return;
    BOOL sec = [url startAccessingSecurityScopedResource];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    if (sec) [url stopAccessingSecurityScopedResource];
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
    [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)ctrl {}
@end

// --- Menu ---
static UIViewController *vcam_topVC(void) {
    UIWindow *w = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *win in ((UIWindowScene *)s).windows) { if (win.isKeyWindow) { w = win; break; } }
            if (w) break;
        }
    }
    if (!w) w = [UIApplication sharedApplication].windows.firstObject;
    if (!w) return nil;
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void vcam_showMenu(void) {
    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;
    BOOL enabled = vcam_flagExists(); BOOL hasVideo = vcam_videoExists();
    NSString *vi = hasVideo ? [NSString stringWithFormat:@"%.1f MB",
        [[[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_VIDEO error:nil] fileSize] / 1048576.0] : @"无";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCam Plus v6.0"
        message:[NSString stringWithFormat:@"开关: %@\n视频: %@", enabled ? @"已开启" : @"已关闭", vi]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"从相册选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC(); if (!vc) return;
            UIImagePickerController *p = [[UIImagePickerController alloc] init];
            p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            p.mediaTypes = @[@"public.movie"]; p.delegate = [VCamUIHelper shared];
            [vc presentViewController:p animated:YES completion:nil];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"从文件选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC(); if (!vc) return;
            UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
                initWithDocumentTypes:@[@"public.movie", @"public.video"] inMode:UIDocumentPickerModeImport];
            p.delegate = [VCamUIHelper shared];
            [vc presentViewController:p animated:YES completion:nil];
        });
    }]];
    if (enabled) {
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭虚拟摄像头" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
            [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
            [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
        }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"开启虚拟摄像头" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"查看诊断日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *log = [NSString stringWithContentsOfFile:VCAM_LOG encoding:NSUTF8StringEncoding error:nil];
            if (!log || log.length == 0) log = @"(空)";
            if (log.length > 2000) log = [log substringFromIndex:log.length - 2000];
            UIAlertController *la = [UIAlertController alertControllerWithTitle:@"诊断日志" message:log preferredStyle:UIAlertControllerStyleAlert];
            [la addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a2) {
                [@"" writeToFile:VCAM_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }]];
            [la addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [vcam_topVC() presentViewController:la animated:YES completion:nil];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [topVC presentViewController:alert animated:YES completion:nil];
}

// --- SpringBoard hooks ---
%group SBHooks
%hook SBVolumeControl
- (void)increaseVolume {
    %orig;
    NSTimeInterval now = CACurrentMediaTime(); gLastUpTime = now;
    if (gLastDownTime > 0 && (now - gLastDownTime) < 1.5) {
        gLastUpTime = 0; gLastDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{ vcam_showMenu(); });
    }
}
- (void)decreaseVolume {
    %orig;
    NSTimeInterval now = CACurrentMediaTime(); gLastDownTime = now;
    if (gLastUpTime > 0 && (now - gLastUpTime) < 1.5) {
        gLastUpTime = 0; gLastDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{ vcam_showMenu(); });
    }
}
%end
%end

// --- Camera hooks ---
%group CamHooks
%hook CALayer
- (void)addSublayer:(CALayer *)layer {
    %orig;
    @try {
        if (!gPreviewLayerClass || ![layer isKindOfClass:gPreviewLayerClass]) return;
        if (!vcam_isEnabled()) return;
        vcam_log(@"PreviewLayer detected");
        [VCamOverlay attachToPreviewLayer:layer];
    } @catch (NSException *e) {}
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    @try {
        if (delegate) {
            VCamDelegateProxy *proxy = [[VCamDelegateProxy alloc] init];
            proxy.realDelegate = delegate;
            objc_setAssociatedObject(self, &kProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            vcam_log([NSString stringWithFormat:@"Proxy for: %@", NSStringFromClass(object_getClass(delegate))]);
            %orig((id)proxy, queue);
            return;
        }
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"Proxy error: %@", e]);
    }
    objc_setAssociatedObject(self, &kProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}

- (id)sampleBufferDelegate {
    @try {
        VCamDelegateProxy *proxy = objc_getAssociatedObject(self, &kProxyKey);
        if (proxy && proxy.realDelegate) return proxy.realDelegate;
    } @catch (NSException *e) {}
    return %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning { %orig; @try { vcam_log(@"AVCaptureSession startRunning"); } @catch (NSException *e) {} }
%end
%end

// --- Constructor ---
%ctor {
    @autoreleasepool {
        gLockA = [[NSLock alloc] init];
        gLockB = [[NSLock alloc] init];
        gOverlays = [NSMutableArray new];
        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
        vcam_log([NSString stringWithFormat:@"LOADED in %@ (%@)", proc, bid]);
        gPreviewLayerClass = NSClassFromString(@"AVCaptureVideoPreviewLayer");
        %init(CamHooks);
        vcam_log(@"CamHooks initialized");
        Class sbvc = NSClassFromString(@"SBVolumeControl");
        if (sbvc) { %init(SBHooks); vcam_log(@"SBHooks initialized"); }
    }
}
