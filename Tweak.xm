// VCam Plus v6.2 — In-place pixel replacement via CIContext
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
extern "C" void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

#define VCAM_DIR   @"/var/jb/var/mobile/Library/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"
#define VCAM_LOG   VCAM_DIR @"/debug.log"
static void vcam_showMenu(void);

static void vcam_log(NSString *msg) {
    @try {
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *line = [NSString stringWithFormat:@"[%@] %@: %@\n", ts, proc, msg];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:VCAM_LOG]) [fm createFileAtPath:VCAM_LOG contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:VCAM_LOG];
        [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
    } @catch (NSException *e) {}
}

// --- Globals ---
static NSLock *gLockA = nil, *gLockB = nil;
static AVAssetReader *gReaderA = nil, *gReaderB = nil;
static AVAssetReaderTrackOutput *gOutputA = nil, *gOutputB = nil;
static NSTimeInterval gLastUpTime = 0, gLastDownTime = 0;
static Class gPreviewLayerClass = nil;
static char kOverlayKey;
static NSMutableSet *gHookedClasses = nil;
static NSMutableArray *gOverlays = nil;
static CIContext *gCICtx = nil;

static BOOL vcam_flagExists(void) { return [[NSFileManager defaultManager] fileExistsAtPath:VCAM_FLAG]; }
static BOOL vcam_videoExists(void) { return [[NSFileManager defaultManager] fileExistsAtPath:VCAM_VIDEO]; }
static BOOL vcam_isEnabled(void) { return vcam_flagExists() && vcam_videoExists(); }

// --- Video reader ---
static BOOL vcam_openReader(AVAssetReader *__strong *rdr, AVAssetReaderTrackOutput *__strong *out) {
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
        NSDictionary *s = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:s];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) return NO;
        [reader addOutput:output]; if (![reader startReading]) return NO;
        *rdr = reader; *out = output; return YES;
    } @catch (NSException *e) { return NO; }
}

static CMSampleBufferRef vcam_readFrame(NSLock *lock, AVAssetReader *__strong *rdr, AVAssetReaderTrackOutput *__strong *out) {
    [lock lock];
    @try {
        if (!*rdr || (*rdr).status != AVAssetReaderStatusReading) vcam_openReader(rdr, out);
        CMSampleBufferRef frame = nil;
        if (*rdr) {
            frame = [*out copyNextSampleBuffer];
            if (!frame) { if (vcam_openReader(rdr, out)) frame = [*out copyNextSampleBuffer]; }
        }
        [lock unlock]; return frame;
    } @catch (NSException *e) { [lock unlock]; return NULL; }
}

// ============================================================
// IN-PLACE replacement: render video frame directly into the
// original pixel buffer. CIContext handles BGRA->420v/420f
// conversion automatically. All metadata is preserved.
// ============================================================
static BOOL vcam_replaceInPlace(CMSampleBufferRef sampleBuffer) {
    @try {
        if (!gCICtx) return NO;
        CVImageBufferRef origPB = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!origPB) return NO;
        CMSampleBufferRef frame = vcam_readFrame(gLockA, &gReaderA, &gOutputA);
        if (!frame) return NO;
        CVImageBufferRef srcPB = CMSampleBufferGetImageBuffer(frame);
        if (!srcPB) { CFRelease(frame); return NO; }
        CIImage *img = [CIImage imageWithCVImageBuffer:srcPB];
        if (!img) { CFRelease(frame); return NO; }
        size_t w = CVPixelBufferGetWidth(origPB);
        size_t h = CVPixelBufferGetHeight(origPB);
        CGRect ext = img.extent;
        if (ext.size.width > 0 && ext.size.height > 0 && (ext.size.width != w || ext.size.height != h)) {
            CGFloat sx = (CGFloat)w / ext.size.width;
            CGFloat sy = (CGFloat)h / ext.size.height;
            img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
        }
        [gCICtx render:img toCVPixelBuffer:origPB];
        CFRelease(frame);
        return YES;
    } @catch (NSException *e) { return NO; }
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
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
            kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx); CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(pxb, kCVPixelBufferLock_ReadOnly);
        CFRelease(buf); return img;
    } @catch (NSException *e) { CFRelease(buf); return NULL; }
}

// --- Hook delegate class (early or dynamic) ---
typedef void (*OrigCapIMP)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);

static void vcam_hookClass(Class cls) {
    @try {
        if (!cls) return;
        NSString *cn = NSStringFromClass(cls);
        @synchronized(gHookedClasses) {
            if ([gHookedClasses containsObject:cn]) return;
            [gHookedClasses addObject:cn];
        }
        SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            @synchronized(gHookedClasses) { [gHookedClasses removeObject:cn]; }
            return;
        }
        IMP cur = method_getImplementation(m);
        class_addMethod(cls, sel, cur, method_getTypeEncoding(m));
        IMP *store = (IMP *)calloc(1, sizeof(IMP));
        if (!store) return;
        *store = cur;
        SEL cs = sel;
        __block int logCount = 0;
        NSString *capCN = cn;
        IMP hook = imp_implementationWithBlock(
            ^(id _s, AVCaptureOutput *o, CMSampleBufferRef sb, AVCaptureConnection *c) {
                @try {
                    OrigCapIMP fn = (OrigCapIMP)(*store);
                    if (!fn) return;
                    if (vcam_isEnabled()) {
                        BOOL ok = vcam_replaceInPlace(sb);
                        if (logCount < 3) {
                            logCount++;
                            CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                            OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
                            vcam_log([NSString stringWithFormat:@"Frame %@: replace=%@ fmt=%u %zux%zu",
                                capCN, ok ? @"YES" : @"NO", (unsigned)fmt,
                                pb ? CVPixelBufferGetWidth(pb) : 0, pb ? CVPixelBufferGetHeight(pb) : 0]);
                        }
                    }
                    fn(_s, cs, o, sb, c);
                } @catch (NSException *e) {}
            });
        MSHookMessageEx(cls, sel, hook, store);
        vcam_log([NSString stringWithFormat:@"Hooked: %@", cn]);
    } @catch (NSException *e) {}
}

// --- Overlay ---
@interface VCamOverlay : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, weak) CALayer *previewLayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) int failCount;
+ (void)attachTo:(CALayer *)pl;
@end
@implementation VCamOverlay
+ (void)attachTo:(CALayer *)previewLayer {
    @try {
        if (!vcam_isEnabled()) return;
        VCamOverlay *ex = objc_getAssociatedObject(previewLayer, &kOverlayKey);
        if (ex && ex.layer.superlayer) return;
        if (ex) {
            [ex.timer invalidate]; [ex.layer removeFromSuperlayer];
            @synchronized(gOverlays) { [gOverlays removeObject:ex]; }
        }
        VCamOverlay *ctrl = [[VCamOverlay alloc] init];
        ctrl.previewLayer = previewLayer;
        CALayer *ov = [CALayer layer];
        ov.frame = previewLayer.bounds;
        ov.contentsGravity = kCAGravityResizeAspectFill;
        ov.masksToBounds = YES; ov.hidden = YES;
        ctrl.layer = ov;
        CALayer *par = previewLayer.superlayer;
        if (par) [par insertSublayer:ov above:previewLayer];
        else [previewLayer addSublayer:ov];
        ctrl.timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *t) {
            @try { [ctrl tick]; } @catch (NSException *e) {}
        }];
        objc_setAssociatedObject(previewLayer, &kOverlayKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized(gOverlays) { [gOverlays addObject:ctrl]; }
        vcam_log(@"Overlay attached");
    } @catch (NSException *e) {}
}
- (void)tick {
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

// --- UI ---
@interface VCamUIHelper : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
+ (instancetype)shared;
@end
@implementation VCamUIHelper
+ (instancetype)shared {
    static VCamUIHelper *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [[VCamUIHelper alloc] init]; }); return i;
}
- (void)imagePickerController:(UIImagePickerController *)p didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [p dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = info[UIImagePickerControllerMediaURL]; if (!url) return;
    [[NSFileManager defaultManager] removeItemAtPath:VCAM_VIDEO error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
    [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)p { [p dismissViewControllerAnimated:YES completion:nil]; }
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject; if (!url) return;
    BOOL sec = [url startAccessingSecurityScopedResource];
    [[NSFileManager defaultManager] removeItemAtPath:VCAM_VIDEO error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    if (sec) [url stopAccessingSecurityScopedResource];
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
    [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c {}
@end

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
    BOOL en = vcam_flagExists(); BOOL hv = vcam_videoExists();
    NSString *vi = hv ? [NSString stringWithFormat:@"%.1f MB",
        [[[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_VIDEO error:nil] fileSize] / 1048576.0] : @"无";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"VCam Plus v6.2"
        message:[NSString stringWithFormat:@"开关: %@\n视频: %@", en ? @"已开启" : @"已关闭", vi]
        preferredStyle:UIAlertControllerStyleAlert];
    // version tag for menu
    a.title = @"VCam Plus v6.2.2";
    [a addAction:[UIAlertAction actionWithTitle:@"从相册选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC(); if (!vc) return;
            UIImagePickerController *p = [[UIImagePickerController alloc] init];
            p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            p.mediaTypes = @[@"public.movie"]; p.delegate = [VCamUIHelper shared];
            [vc presentViewController:p animated:YES completion:nil];
        });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"从文件选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC(); if (!vc) return;
            UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
                initWithDocumentTypes:@[@"public.movie", @"public.video"] inMode:UIDocumentPickerModeImport];
            p.delegate = [VCamUIHelper shared];
            [vc presentViewController:p animated:YES completion:nil];
        });
    }]];
    if (en) {
        [a addAction:[UIAlertAction actionWithTitle:@"关闭虚拟摄像头" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
            [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
            [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
        }]];
    } else {
        [a addAction:[UIAlertAction actionWithTitle:@"开启虚拟摄像头" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"查看诊断日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *log = [NSString stringWithContentsOfFile:VCAM_LOG encoding:NSUTF8StringEncoding error:nil];
            if (!log || log.length == 0) log = @"(空)";
            if (log.length > 2000) log = [log substringFromIndex:log.length - 2000];
            UIAlertController *la = [UIAlertController alertControllerWithTitle:@"诊断日志" message:log preferredStyle:UIAlertControllerStyleAlert];
            [la addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x2) {
                [@"" writeToFile:VCAM_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }]];
            [la addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [vcam_topVC() presentViewController:la animated:YES completion:nil];
        });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [topVC presentViewController:a animated:YES completion:nil];
}

// --- Hooks (all in default group) ---
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

%hook CALayer
- (void)addSublayer:(CALayer *)layer {
    %orig;
    @try {
        if (!gPreviewLayerClass || ![layer isKindOfClass:gPreviewLayerClass]) return;
        if (!vcam_isEnabled()) return;
        vcam_log(@"PreviewLayer detected");
        [VCamOverlay attachTo:layer];
    } @catch (NSException *e) {}
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    @try {
        if (delegate) {
            Class cls = object_getClass(delegate);
            vcam_log([NSString stringWithFormat:@"setDelegate: %@", NSStringFromClass(cls)]);
            vcam_hookClass(cls);
        }
    } @catch (NSException *e) {}
    %orig;
}
%end

%hook AVSampleBufferDisplayLayer
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sb {
    @try {
        if (vcam_isEnabled() && sb) vcam_replaceInPlace(sb);
    } @catch (NSException *e) {}
    %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning { %orig; @try { vcam_log(@"AVCaptureSession startRunning"); } @catch (NSException *e) {} }
%end

%ctor {
    @autoreleasepool {
        gLockA = [[NSLock alloc] init];
        gLockB = [[NSLock alloc] init];
        gOverlays = [NSMutableArray new];
        gHookedClasses = [NSMutableSet new];
        gCICtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
        vcam_log([NSString stringWithFormat:@"LOADED in %@ (%@)", proc, bid]);
        gPreviewLayerClass = NSClassFromString(@"AVCaptureVideoPreviewLayer");
        NSArray *known = @[@"IESMMCaptureKit", @"AWECameraAdapter", @"HTSLiveCaptureKit",
            @"IESLiveCaptureKit", @"IESMMCameraSession"];
        for (NSString *name in known) {
            Class cls = NSClassFromString(name);
            if (cls) vcam_hookClass(cls);
        }
        %init;
        vcam_log(@"Hooks initialized");
    }
}
