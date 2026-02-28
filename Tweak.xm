#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import <UIKit/UIKit.h>

//
// VCam Plus v2 - Virtual camera tweak for iOS 16 + Dopamine rootless
//
// Features:
//   - Replace camera in all apps AND Safari web pages
//   - Volume Up + Down to toggle control panel
//   - GUI: on/off switch, select video from Photos or Files
//

#define VCAM_DIR   @"/var/mobile/Library/Caches/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_FLAG  VCAM_DIR @"/enabled"

// ============================================================
// Forward declarations
// ============================================================
static void vcam_togglePanel(void);
static void vcam_updatePanelUI(void);
static void vcam_dismissPanel(void);

// ============================================================
// Global state
// ============================================================
static NSLock                    *gLock       = nil;
static AVAssetReader             *gReader     = nil;
static AVAssetReaderTrackOutput  *gOutput     = nil;
static NSMutableSet              *gProxies    = nil;

// Volume button detection
static float          gPrevVolume   = -1;
static NSTimeInterval gLastUpTime   = 0;
static NSTimeInterval gLastDownTime = 0;

// UI
static UIView   *gPanelView    = nil;
static UISwitch *gEnableSwitch = nil;
static UILabel  *gVideoLabel   = nil;
static UILabel  *gStatusLabel  = nil;

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

static NSString *vcam_videoInfo(void) {
    if (!vcam_videoExists()) return @"No video selected";
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_VIDEO error:nil];
    unsigned long long s = a.fileSize;
    if (s < 1024)        return [NSString stringWithFormat:@"video.mp4 (%llu B)", s];
    if (s < 1024*1024)   return [NSString stringWithFormat:@"video.mp4 (%.1f KB)", s/1024.0];
    return [NSString stringWithFormat:@"video.mp4 (%.1f MB)", s/(1024.0*1024.0)];
}

static void vcam_copyVideoFrom(NSURL *srcURL) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:VCAM_VIDEO error:nil];
    [fm copyItemAtURL:srcURL toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    // Reset reader so next frame uses new video
    [gLock lock];
    gReader = nil;
    gOutput = nil;
    [gLock unlock];
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
// Proxy delegate - intercepts camera frames
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
// Panel Helper - handles video picking & button actions
// ============================================================
@interface VCamPanelHelper : NSObject
    <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
+ (instancetype)shared;
@end

@implementation VCamPanelHelper

+ (instancetype)shared {
    static VCamPanelHelper *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCamPanelHelper alloc] init]; });
    return inst;
}

- (UIViewController *)topVC {
    UIWindowScene *ws = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { ws = (UIWindowScene *)s; break; }
    }
    UIWindow *win = nil;
    for (UIWindow *w in ws.windows) {
        if (w.isKeyWindow) { win = w; break; }
    }
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)closePanel {
    vcam_dismissPanel();
}

- (void)toggleEnabled {
    if (vcam_flagExists()) {
        [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
    } else {
        [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [gLock lock];
    gReader = nil;
    gOutput = nil;
    [gLock unlock];
    vcam_updatePanelUI();
}

- (void)pickFromPhotos {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.movie"];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self topVC] presentViewController:picker animated:YES completion:nil];
}

- (void)pickFromFiles {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.movie"]
                                                              inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self topVC] presentViewController:picker animated:YES completion:nil];
}

// UIImagePickerControllerDelegate
- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;
    vcam_copyVideoFrom(url);
    dispatch_async(dispatch_get_main_queue(), ^{ vcam_updatePanelUI(); });
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
    vcam_copyVideoFrom(url);
    if (sec) [url stopAccessingSecurityScopedResource];
    vcam_updatePanelUI();
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)ctrl {}

- (void)bgTapped:(UITapGestureRecognizer *)tap {
    CGPoint pt = [tap locationInView:gPanelView];
    for (UIView *sub in gPanelView.subviews) {
        if (CGRectContainsPoint(sub.frame, pt)) return;
    }
    vcam_dismissPanel();
}

@end

// ============================================================
// Panel UI
// ============================================================
static UIButton *vcam_makeBtn(NSString *title, UIColor *bg, CGRect frame, SEL action) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = bg;
    btn.layer.cornerRadius = 8;
    btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [btn addTarget:[VCamPanelHelper shared] action:action
      forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

static void vcam_createPanel(void) {
    if (gPanelView) return;

    UIWindow *window = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
    }
    if (!window) return;

    CGRect sb = window.bounds;

    gPanelView = [[UIView alloc] initWithFrame:sb];
    gPanelView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    gPanelView.alpha = 0;

    UITapGestureRecognizer *bgTap =
        [[UITapGestureRecognizer alloc] initWithTarget:[VCamPanelHelper shared]
                                                action:@selector(bgTapped:)];
    [gPanelView addGestureRecognizer:bgTap];

    CGFloat cw = 300, ch = 340;
    UIView *card = [[UIView alloc] initWithFrame:
        CGRectMake((sb.size.width - cw)/2, (sb.size.height - ch)/2, cw, ch)];
    card.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;
    [gPanelView addSubview:card];

    CGFloat y = 16;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw - 70, 30)];
    title.text = @"VCam Plus";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:20];
    [card addSubview:title];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(cw - 50, y, 40, 30);
    [closeBtn setTitle:@"X" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.6 alpha:1] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [closeBtn addTarget:[VCamPanelHelper shared] action:@selector(closePanel)
       forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];
    y += 42;

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(16, y, cw - 32, 1)];
    sep.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    [card addSubview:sep];
    y += 16;

    UILabel *enLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 160, 31)];
    enLbl.text = @"Virtual Camera:";
    enLbl.textColor = [UIColor whiteColor];
    enLbl.font = [UIFont systemFontOfSize:16];
    [card addSubview:enLbl];

    gEnableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cw - 67, y, 51, 31)];
    [gEnableSwitch addTarget:[VCamPanelHelper shared] action:@selector(toggleEnabled)
            forControlEvents:UIControlEventValueChanged];
    [card addSubview:gEnableSwitch];
    y += 44;

    gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw - 32, 22)];
    gStatusLabel.font = [UIFont systemFontOfSize:13];
    [card addSubview:gStatusLabel];
    y += 28;

    UILabel *vidTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw - 32, 22)];
    vidTitle.text = @"Current Video:";
    vidTitle.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    vidTitle.font = [UIFont systemFontOfSize:14];
    [card addSubview:vidTitle];
    y += 22;

    gVideoLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw - 32, 22)];
    gVideoLabel.textColor = [UIColor whiteColor];
    gVideoLabel.font = [UIFont systemFontOfSize:14];
    [card addSubview:gVideoLabel];
    y += 36;

    UIColor *blue = [UIColor colorWithRed:0.2 green:0.48 blue:1.0 alpha:1];
    UIColor *gray = [UIColor colorWithWhite:0.28 alpha:1];

    [card addSubview:vcam_makeBtn(@"Select from Photos", blue,
        CGRectMake(16, y, cw - 32, 42), @selector(pickFromPhotos))];
    y += 50;

    [card addSubview:vcam_makeBtn(@"Select from Files", gray,
        CGRectMake(16, y, cw - 32, 42), @selector(pickFromFiles))];

    vcam_updatePanelUI();

    [window addSubview:gPanelView];
    [UIView animateWithDuration:0.25 animations:^{ gPanelView.alpha = 1; }];
}

static void vcam_updatePanelUI(void) {
    if (!gVideoLabel) return;
    gVideoLabel.text = vcam_videoInfo();
    gEnableSwitch.on = vcam_flagExists();
    if (vcam_isEnabled()) {
        gStatusLabel.text = @"Status: Active";
        gStatusLabel.textColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.3 alpha:1];
    } else if (vcam_videoExists()) {
        gStatusLabel.text = @"Status: Off";
        gStatusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    } else {
        gStatusLabel.text = @"Status: No video selected";
        gStatusLabel.textColor = [UIColor colorWithRed:1.0 green:0.4 blue:0.3 alpha:1];
    }
}

static void vcam_dismissPanel(void) {
    if (!gPanelView) return;
    [UIView animateWithDuration:0.2 animations:^{
        gPanelView.alpha = 0;
    } completion:^(BOOL ok) {
        [gPanelView removeFromSuperview];
        gPanelView = nil;
        gEnableSwitch = nil;
        gVideoLabel = nil;
        gStatusLabel = nil;
    }];
}

static void vcam_togglePanel(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ vcam_togglePanel(); });
        return;
    }
    if (gPanelView) vcam_dismissPanel();
    else vcam_createPanel();
}

// ============================================================
// Volume button detection
// ============================================================
static void vcam_volumeChanged(NSNotification *note) {
    NSString *reason = note.userInfo[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];
    if (![reason isEqualToString:@"ExplicitVolumeChange"]) return;

    float vol = [note.userInfo[@"AVSystemController_AudioVolumeNotificationParameter"] floatValue];
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();

    if (gPrevVolume >= 0) {
        if (vol > gPrevVolume) {
            gLastUpTime = now;
        } else if (vol < gPrevVolume) {
            gLastDownTime = now;
        }
        if (gLastUpTime > 0 && gLastDownTime > 0 &&
            fabs(gLastUpTime - gLastDownTime) < 0.5) {
            gLastUpTime = 0;
            gLastDownTime = 0;
            vcam_togglePanel();
        }
    }
    gPrevVolume = vol;
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

        // Volume button + UI only in UIKit apps (not WebContent)
        if ([UIApplication sharedApplication]) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            vcam_volumeChanged(note);
                        }];
        }
    }
}
