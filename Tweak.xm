// Tweak.xm
#import "VCAMOverlay.h"
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import <notify.h>

// ── SpringBoard: Hook volume buttons ──────────────────────────────────────────
// Runs inside SpringBoard process

static NSTimeInterval lastInc = 0;
static NSTimeInterval lastDec = 0;
static NSTimeInterval lastToggle = 0;

%group SpringBoard

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

// ── mediaserverd: Hook camera to inject virtual video ─────────────────────────
// Runs inside mediaserverd process

static NSString *kPrefsPath  = @"/var/tmp/com.vcamlight.cache/prefs.plist";
static NSString *kVideoPath  = @"/var/tmp/com.vcamlight.cache/selected.mov";
static NSString *kDarwinNote = @"com.vcamlight.videochanged";

// Current replacement frame data
static dispatch_queue_t gDecodeQueue = nil;
static AVAssetReader    *gReader     = nil;
static AVAssetReaderTrackOutput *gTrackOutput = nil;
static BOOL             gReplacing  = NO;
static BOOL             gLooping    = NO;

static void vcam_setupReader(NSString *path) {
    @try {
        [gReader cancelReading];
        gReader = nil; gTrackOutput = nil;

        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;

        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!track) return;

        NSError *err;
        gReader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
        if (err) return;

        NSDictionary *settings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        gTrackOutput = [[AVAssetReaderTrackOutput alloc]
                        initWithTrack:track outputSettings:settings];
        gTrackOutput.alwaysCopiesSampleData = NO;
        [gReader addOutput:gTrackOutput];
        [gReader startReading];
    } @catch (...) {}
}

static CVPixelBufferRef vcam_nextFrame(void) {
    if (!gTrackOutput) return NULL;

    CMSampleBufferRef sample = [gTrackOutput copyNextSampleBuffer];
    if (!sample) {
        // Loop: restart reader
        if (gLooping) {
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
            NSString *path = prefs[@"galName"] ?: kVideoPath;
            vcam_setupReader(path);
            if (gTrackOutput) {
                sample = [gTrackOutput copyNextSampleBuffer];
            }
        }
        if (!sample) return NULL;
    }

    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sample);
    if (px) CVPixelBufferRetain(px);
    CFRelease(sample);
    return px;
}

%group MediaServerd

// Hook AVCaptureVideoDataOutput delegate callback inside mediaserverd
%hook AVCaptureOutput

- (void)_AVOutputContext_notifyObserversOfNewSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                           forConnection:(id)connection {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    BOOL replOn = [prefs[@"replOn"] boolValue];

    if (!replOn) {
        %orig;
        return;
    }

    // Get replacement frame
    CVPixelBufferRef px = vcam_nextFrame();
    if (!px) { %orig; return; }

    // Build a new sample buffer with the replacement pixel buffer
    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);

    CMVideoFormatDescriptionRef fmt;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, px, &fmt);

    CMSampleBufferRef newSample = NULL;
    CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, px, true, NULL, NULL, fmt, &timing, &newSample);

    CFRelease(px);
    CFRelease(fmt);

    if (newSample) {
        // Replace the original call with our modified buffer
        %orig(newSample, connection);
        CFRelease(newSample);
    } else {
        %orig;
    }
}

%end

%end // MediaServerd

// ── Init ──────────────────────────────────────────────────────────────────────
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSString *processName = [[NSProcessInfo processInfo] processName];
    
    // Create cache directory if needed
    [[NSFileManager defaultManager]
        createDirectoryAtPath:@"/var/tmp/com.vcamlight.cache"
        withIntermediateDirectories:YES
        attributes:nil
        error:nil];

    gDecodeQueue = dispatch_queue_create("com.vcamlight.decode", DISPATCH_QUEUE_SERIAL);

    if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        // SpringBoard: hook volume buttons
        %init(SpringBoard);

    } else if ([processName isEqualToString:@"mediaserverd"]) {
        // mediaserverd: hook camera
        %init(MediaServerd);

        // Listen for video change notifications from the overlay
        int notifyToken = 0;
        notify_register_dispatch(
            [kDarwinNote UTF8String],
            &notifyToken,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
            ^(int token) {
                NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
                NSString *path = prefs[@"galName"] ?: kVideoPath;
                gReplacing = [prefs[@"replOn"] boolValue];
                gLooping   = [prefs[@"loopOn"] boolValue];
                if (gReplacing) vcam_setupReader(path);
            }
        );

        // Load existing prefs on startup
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
        gReplacing = [prefs[@"replOn"] boolValue];
        gLooping   = [prefs[@"loopOn"] boolValue];
        if (gReplacing) {
            NSString *path = prefs[@"galName"] ?: kVideoPath;
            vcam_setupReader(path);
        }
    }
}
