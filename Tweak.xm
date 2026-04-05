// Tweak.xm
// VCAMLight — hooks volume buttons in SpringBoard to show the overlay,
// and hooks AVCaptureVideoDataOutput in camera-using apps to inject
// the selected video as the camera feed.

#import "VCAMOverlay.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>

// ── SpringBoard: Hook volume buttons ──────────────────────────────────────────
// Runs inside SpringBoard process

%group SpringBoard

static NSTimeInterval lastInc = 0;
static NSTimeInterval lastDec = 0;
static NSTimeInterval lastToggle = 0;

%hook SBVolumeControl

- (void)increaseVolume {
    %orig;
    lastInc = CACurrentMediaTime();
    if (ABS(lastInc - lastDec) < 0.2 && (lastInc - lastToggle > 1.0)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCAMOverlay toggle];
        });
        lastToggle = CACurrentMediaTime();
    }
}

- (void)decreaseVolume {
    %orig;
    lastDec = CACurrentMediaTime();
    if (ABS(lastInc - lastDec) < 0.2 && (lastDec - lastToggle > 1.0)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCAMOverlay toggle];
        });
        lastToggle = CACurrentMediaTime();
    }
}

%end

%end // SpringBoard

// ── Camera Apps: Hook AVCaptureVideoDataOutput to inject virtual video ─────────
// Runs inside any app that uses the camera

static NSString *kPrefsPath  = @"/var/tmp/com.vcamlight.cache/prefs.plist";
static NSString *kVideoPath  = @"/var/tmp/com.vcamlight.cache/selected.mov";
static NSString *kDarwinNote = @"com.vcamlight.videochanged";
static NSString *kLoginNote  = @"com.vcamlight.loginchanged";

// Current replacement frame state
static AVAssetReader              *gReader      = nil;
static AVAssetReaderTrackOutput   *gTrackOutput = nil;
static BOOL                        gReplacing   = NO;
static BOOL                        gLooping     = YES;
static dispatch_queue_t            gDecodeQueue = nil;
static NSLock                     *gReaderLock  = nil;

// Track swizzled delegates to avoid double-swizzle
static NSMutableSet *gSwizzledClasses = nil;

// Original IMP storage
static void (*gOrigCaptureOutput)(id, SEL, AVCaptureOutput*,
    CMSampleBufferRef, AVCaptureConnection*);

// ── Video reader setup ────────────────────────────────────────────────────────

static void vcam_setupReader(NSString *path) {
    [gReaderLock lock];
    @try {
        [gReader cancelReading];
        gReader = nil;
        gTrackOutput = nil;

        if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path])  {
            [gReaderLock unlock];
            return;
        }

        NSURL *url = [NSURL fileURLWithPath:path];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        AVAssetTrack *track = tracks.firstObject;
        if (!track) {
            [gReaderLock unlock];
            return;
        }

        NSError *err = nil;
        gReader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
        if (err || !gReader) {
            gReader = nil;
            [gReaderLock unlock];
            return;
        }

        NSDictionary *settings = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
        };
        gTrackOutput = [[AVAssetReaderTrackOutput alloc]
                         initWithTrack:track outputSettings:settings];
        gTrackOutput.alwaysCopiesSampleData = NO;
        [gReader addOutput:gTrackOutput];
        [gReader startReading];
    } @catch (NSException *e) {
        gReader = nil;
        gTrackOutput = nil;
    }
    [gReaderLock unlock];
}

static CVPixelBufferRef vcam_nextFrame(void) {
    [gReaderLock lock];
    if (!gTrackOutput || !gReader) {
        [gReaderLock unlock];
        return NULL;
    }

    CMSampleBufferRef sample = [gTrackOutput copyNextSampleBuffer];
    if (!sample && gLooping) {
        // Loop: re-create reader from the beginning
        [gReader cancelReading];
        gReader = nil;
        gTrackOutput = nil;
        [gReaderLock unlock];

        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
        NSString *path = prefs[@"galName"] ?: kVideoPath;
        vcam_setupReader(path);

        [gReaderLock lock];
        if (gTrackOutput) {
            sample = [gTrackOutput copyNextSampleBuffer];
        }
    }
    [gReaderLock unlock];

    if (!sample) return NULL;

    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sample);
    if (px) CVPixelBufferRetain(px);
    CFRelease(sample);
    return px; // caller must release
}

// ── Replacement delegate method ───────────────────────────────────────────────

static void vcam_replacementCaptureOutput(id self, SEL _cmd,
    AVCaptureOutput *output, CMSampleBufferRef sampleBuffer,
    AVCaptureConnection *connection) {

    // Check if replacement is active
    if (!gReplacing) {
        if (gOrigCaptureOutput) {
            gOrigCaptureOutput(self, _cmd, output, sampleBuffer, connection);
        }
        return;
    }

    // Get replacement frame
    CVPixelBufferRef px = vcam_nextFrame();
    if (!px) {
        if (gOrigCaptureOutput) {
            gOrigCaptureOutput(self, _cmd, output, sampleBuffer, connection);
        }
        return;
    }

    // Build a new CMSampleBuffer with the replacement pixel buffer
    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, px, &fmt);

    if (status != noErr || !fmt) {
        CVPixelBufferRelease(px);
        if (gOrigCaptureOutput) {
            gOrigCaptureOutput(self, _cmd, output, sampleBuffer, connection);
        }
        return;
    }

    CMSampleBufferRef newSample = NULL;
    status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, px, true, NULL, NULL, fmt, &timing, &newSample);

    CFRelease(fmt);

    if (status == noErr && newSample) {
        if (gOrigCaptureOutput) {
            gOrigCaptureOutput(self, _cmd, output, newSample, connection);
        }
        CFRelease(newSample);
    } else {
        if (gOrigCaptureOutput) {
            gOrigCaptureOutput(self, _cmd, output, sampleBuffer, connection);
        }
    }

    CVPixelBufferRelease(px);
}

// ── Swizzle delegate's captureOutput method ───────────────────────────────────

static void vcam_swizzleDelegate(id delegate) {
    if (!delegate) return;

    Class cls = [delegate class];
    NSString *clsName = NSStringFromClass(cls);

    @synchronized(gSwizzledClasses) {
        if ([gSwizzledClasses containsObject:clsName]) return;
        [gSwizzledClasses addObject:clsName];
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    // Store original implementation
    gOrigCaptureOutput = (void (*)(id, SEL, AVCaptureOutput*,
        CMSampleBufferRef, AVCaptureConnection*))method_getImplementation(m);

    // Replace with our function
    method_setImplementation(m, (IMP)vcam_replacementCaptureOutput);
}

%group CameraApps

// Hook AVCaptureVideoDataOutput to intercept delegate setup
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (delegate && gReplacing) {
        vcam_swizzleDelegate(delegate);
    }
}

%end

// Also hook AVCaptureSession to catch when it starts
%hook AVCaptureSession

- (void)startRunning {
    %orig;

    // Check all outputs for video data outputs with delegates
    for (AVCaptureOutput *output in self.outputs) {
        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            AVCaptureVideoDataOutput *vdo = (AVCaptureVideoDataOutput *)output;
            id delegate = [vdo sampleBufferDelegate];
            if (delegate && gReplacing) {
                vcam_swizzleDelegate(delegate);
            }
        }
    }
}

%end

%end // CameraApps

// ── Init ──────────────────────────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];

        if ([bundleId isEqualToString:@"com.apple.springboard"]) {
            // SpringBoard: hook volume buttons
            %init(SpringBoard);

        } else {
            // Camera apps: hook AVCaptureVideoDataOutput delegates
            gDecodeQueue = dispatch_queue_create(
                "com.vcamlight.decode", DISPATCH_QUEUE_SERIAL);
            gReaderLock = [[NSLock alloc] init];
            gSwizzledClasses = [NSMutableSet new];

            // Create cache directory
            [[NSFileManager defaultManager]
                createDirectoryAtPath:@"/var/tmp/com.vcamlight.cache"
                withIntermediateDirectories:YES
                attributes:nil
                error:nil];

            // Load existing prefs
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
            gReplacing = [prefs[@"replOn"] boolValue];
            gLooping   = [prefs[@"loopOn"] boolValue];

            if (gReplacing) {
                NSString *path = prefs[@"galName"] ?: kVideoPath;
                vcam_setupReader(path);
            }

            // Listen for video change notifications
            int notifyToken = 0;
            notify_register_dispatch(
                [kDarwinNote UTF8String],
                &notifyToken,
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                ^(int __unused token) {
                    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
                    gReplacing = [p[@"replOn"] boolValue];
                    gLooping   = [p[@"loopOn"] boolValue];
                    if (gReplacing) {
                        NSString *path = p[@"galName"] ?: kVideoPath;
                        vcam_setupReader(path);
                    } else {
                        [gReaderLock lock];
                        [gReader cancelReading];
                        gReader = nil;
                        gTrackOutput = nil;
                        [gReaderLock unlock];
                    }
                }
            );

            %init(CameraApps);
        }
    }
}
