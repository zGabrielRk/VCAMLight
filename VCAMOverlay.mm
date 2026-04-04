// VCAMOverlay.mm
// Minimal virtual camera overlay — no login, no session, no wallet.
// Volume +/- → shows overlay → select video → apply to camera.

#import "VCAMOverlay.h"
#import <PhotosUI/PHPickerViewController.h>
#import <PhotosUI/PHPickerFilter.h>
#import <PhotosUI/PHPickerConfiguration.h>
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVAsset.h>

// ── Shared prefs path (LordVCAM reads from here too) ─────────────────────────
static NSString *const kPrefsPath  = @"/var/tmp/com.apple.avfcache/prefs.plist";
static NSString *const kVideoPath  = @"/var/tmp/com.apple.avfcache/selected.mov";
static NSString *const kDarwinNote = @"com.vcamlight.videochanged";

// ── Colors ────────────────────────────────────────────────────────────────────
#define COLOR_BG        [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:1]
#define COLOR_SURFACE   [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:1]
#define COLOR_PURPLE    [UIColor colorWithRed:0.69 green:0.43 blue:0.95 alpha:1]
#define COLOR_PURPLE_DK [UIColor colorWithRed:0.49 green:0.23 blue:0.87 alpha:1]
#define COLOR_TEXT      [UIColor colorWithRed:0.91 green:0.91 blue:0.94 alpha:1]
#define COLOR_MUTED     [UIColor colorWithRed:0.42 green:0.42 blue:0.50 alpha:1]
#define COLOR_GREEN     [UIColor colorWithRed:0.29 green:0.86 blue:0.50 alpha:1]

@interface VCAMOverlay () <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIWindow         *overlayWindow;
@property (nonatomic, strong) UIView           *card;
@property (nonatomic, strong) UIView           *previewContainer;
@property (nonatomic, strong) AVPlayer         *player;
@property (nonatomic, strong) AVPlayerLayer    *playerLayer;
@property (nonatomic, strong) UILabel          *previewLabel;
@property (nonatomic, strong) UILabel          *statusLabel;
@property (nonatomic, strong) UIButton         *selectBtn;
@property (nonatomic, strong) UIButton         *previewBtn;
@property (nonatomic, strong) UIButton         *applyBtn;
@property (nonatomic, strong) NSURL            *selectedVideoURL;
@property (nonatomic, assign) BOOL             applied;
@end

@implementation VCAMOverlay

+ (instancetype)shared {
    static VCAMOverlay *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [VCAMOverlay new]; });
    return s;
}

// ── Toggle show/hide ──────────────────────────────────────────────────────────
+ (void)toggle {
    VCAMOverlay *ov = [self shared];
    if (ov.overlayWindow && !ov.overlayWindow.hidden) {
        [ov hide];
    } else {
        [ov show];
    }
}

+ (void)show  { [[self shared] show]; }
+ (void)hide  { [[self shared] hide]; }

// ── Build window ──────────────────────────────────────────────────────────────
- (void)show {
    if (!self.overlayWindow) [self buildUI];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.overlayWindow.hidden = NO;
        self.card.transform = CGAffineTransformMakeTranslation(0, 60);
        self.card.alpha = 0;
        [UIView animateWithDuration:0.35
                              delay:0
             usingSpringWithDamping:0.78
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.card.transform = CGAffineTransformIdentity;
            self.card.alpha = 1;
        } completion:nil];
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.22
                         animations:^{
            self.card.transform = CGAffineTransformMakeTranslation(0, 40);
            self.card.alpha = 0;
        } completion:^(BOOL done) {
            self.overlayWindow.hidden = YES;
        }];
    });
}

// ── Build UI ──────────────────────────────────────────────────────────────────
- (void)buildUI {
    // Window
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s; break;
        }
    }
    if (scene) {
        self.overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        self.overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    self.overlayWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    self.overlayWindow.hidden = NO;

    // Tap backdrop to dismiss
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(backdropTapped)];
    [self.overlayWindow addGestureRecognizer:tap];

    // Root VC (needed for presentation)
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow.rootViewController = root;

    CGFloat sw = [UIScreen mainScreen].bounds.size.width;

    // Card
    CGFloat cardW = MIN(sw - 32, 360);
    CGFloat cardH = 480;
    CGFloat cardX = (sw - cardW) / 2;
    CGFloat cardY = ([UIScreen mainScreen].bounds.size.height - cardH) / 2;

    self.card = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    self.card.backgroundColor = COLOR_BG;
    self.card.layer.cornerRadius = 24;
    self.card.layer.masksToBounds = YES;
    self.card.alpha = 0;

    // Purple top accent line
    UIView *accent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, 2)];
    accent.backgroundColor = COLOR_PURPLE;
    [self.card addSubview:accent];

    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 16, cardW-40, 22)];
    title.text = @"VCAMLight";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = COLOR_PURPLE;
    title.textAlignment = NSTextAlignmentCenter;
    title.alpha = 0.85;
    [self.card addSubview:title];

    // Preview area
    CGFloat prevH = 200;
    self.previewContainer = [[UIView alloc] initWithFrame:CGRectMake(16, 48, cardW-32, prevH)];
    self.previewContainer.backgroundColor = COLOR_SURFACE;
    self.previewContainer.layer.cornerRadius = 16;
    self.previewContainer.layer.masksToBounds = YES;
    [self.card addSubview:self.previewContainer];

    self.previewLabel = [[UILabel alloc] initWithFrame:self.previewContainer.bounds];
    self.previewLabel.text = @"Preview do Vídeo";
    self.previewLabel.font = [UIFont systemFontOfSize:13];
    self.previewLabel.textColor = COLOR_MUTED;
    self.previewLabel.textAlignment = NSTextAlignmentCenter;
    [self.previewContainer addSubview:self.previewLabel];

    // Status label
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 258, cardW-40, 18)];
    self.statusLabel.text = @"Nenhum vídeo selecionado";
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.statusLabel.textColor = COLOR_MUTED;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.card addSubview:self.statusLabel];

    // ── Select / Preview buttons ──
    CGFloat btnY = 286;
    CGFloat btnW = (cardW - 48) / 2;
    CGFloat btnH = 52;

    self.selectBtn = [self makeButton:@"Select"
                                frame:CGRectMake(16, btnY, btnW, btnH)
                               action:@selector(selectTapped)];
    [self.card addSubview:self.selectBtn];

    self.previewBtn = [self makeButton:@"Preview"
                                 frame:CGRectMake(16+btnW+16, btnY, btnW, btnH)
                                action:@selector(previewTapped)];
    self.previewBtn.alpha = 0.5;
    self.previewBtn.enabled = NO;
    [self.card addSubview:self.previewBtn];

    // ── Apply button ──
    self.applyBtn = [self makeButton:@"Apply"
                               frame:CGRectMake(16, btnY+btnH+12, cardW-32, 56)];
    self.applyBtn.alpha = 0.5;
    self.applyBtn.enabled = NO;
    [self.applyBtn addTarget:self action:@selector(applyTapped)
            forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.applyBtn];

    // Close X
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(cardW-44, 10, 34, 34);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:COLOR_MUTED forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [closeBtn addTarget:self action:@selector(hide)
       forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:closeBtn];

    [self.overlayWindow addSubview:self.card];

    // Check if already applied
    [self checkExistingVideo];
}

- (UIButton *)makeButton:(NSString *)title frame:(CGRect)frame {
    return [self makeButton:title frame:frame action:nil];
}

- (UIButton *)makeButton:(NSString *)title frame:(CGRect)frame action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = COLOR_PURPLE;
    btn.layer.cornerRadius = 14;
    btn.layer.masksToBounds = YES;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];

    // Gradient overlay
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = btn.bounds;
    grad.colors = @[(id)[[UIColor colorWithWhite:1 alpha:0.12] CGColor],
                    (id)[[UIColor colorWithWhite:1 alpha:0.0] CGColor]];
    [btn.layer addSublayer:grad];

    if (action) {
        [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }

    // Press animation
    [btn addTarget:self action:@selector(btnDown:)
  forControlEvents:UIControlEventTouchDown|UIControlEventTouchDragEnter];
    [btn addTarget:self action:@selector(btnUp:)
  forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchCancel|UIControlEventTouchDragExit];
    return btn;
}

- (void)btnDown:(UIButton*)b {
    [UIView animateWithDuration:0.1 animations:^{ b.transform=CGAffineTransformMakeScale(0.96,0.96); }];
}
- (void)btnUp:(UIButton*)b {
    [UIView animateWithDuration:0.18 animations:^{ b.transform=CGAffineTransformIdentity; }];
}

- (void)backdropTapped { [self hide]; }

// ── Actions ───────────────────────────────────────────────────────────────────
- (void)selectTapped {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter videosFilter];
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.overlayWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}

- (void)previewTapped {
    if (!self.selectedVideoURL) return;
    [self startPreview:self.selectedVideoURL];
}

- (void)applyTapped {
    if (!self.selectedVideoURL) return;
    [self applyVideo:self.selectedVideoURL];
}

// ── PHPickerViewControllerDelegate ────────────────────────────────────────────
- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    PHPickerResult *result = results.firstObject;
    if (![result.itemProvider hasItemConformingToTypeIdentifier:@"public.movie"] &&
        ![result.itemProvider hasItemConformingToTypeIdentifier:@"public.video"]) return;

    NSString *typeId = [result.itemProvider hasItemConformingToTypeIdentifier:@"public.movie"]
        ? @"public.movie" : @"public.video";

    [result.itemProvider loadFileRepresentationForTypeIdentifier:typeId
                                              completionHandler:^(NSURL *url, NSError *err) {
        if (!url) return;
        // Copy to our stable path
        NSError *copyErr;
        [[NSFileManager defaultManager] removeItemAtPath:kVideoPath error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:url.path
                                                toPath:kVideoPath
                                                 error:&copyErr];
        NSURL *stableURL = copyErr ? url : [NSURL fileURLWithPath:kVideoPath];
        self.selectedVideoURL = stableURL;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *name = url.lastPathComponent ?: @"video";
            self.statusLabel.text = name;
            self.statusLabel.textColor = COLOR_GREEN;
            self.previewBtn.alpha = 1; self.previewBtn.enabled = YES;
            self.applyBtn.alpha  = 1; self.applyBtn.enabled  = YES;
            [self startPreview:stableURL];
        });
    }];
}

// ── Preview ───────────────────────────────────────────────────────────────────
- (void)startPreview:(NSURL *)url {
    if (self.playerLayer) [self.playerLayer removeFromSuperlayer];
    self.player = [AVPlayer playerWithURL:url];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:self.player.currentItem queue:nil usingBlock:^(NSNotification *n) {
        [self.player seekToTime:kCMTimeZero];
        [self.player play];
    }];
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.frame = self.previewContainer.bounds;
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.previewContainer.layer addSublayer:self.playerLayer];
    self.previewLabel.hidden = YES;
    [self.player play];
}

// ── Apply ─────────────────────────────────────────────────────────────────────
- (void)applyVideo:(NSURL *)url {
    // Write prefs that LordVCAM reads
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary new];
    prefs[@"replOn"]    = @YES;
    prefs[@"loopOn"]    = @YES;
    prefs[@"galName"]   = url.path;
    prefs[@"mode"]      = @"gallery";
    [prefs writeToFile:kPrefsPath atomically:YES];

    // Notify mediaserverd via Darwin notification
    notify_post([kDarwinNote UTF8String]);

    // Visual feedback
    self.applyBtn.backgroundColor = COLOR_GREEN;
    [self.applyBtn setTitle:@"✓ Aplicado!" forState:UIControlStateNormal];
    self.applied = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self hide];
        // Reset button after hide
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.applyBtn.backgroundColor = COLOR_PURPLE;
            [self.applyBtn setTitle:@"Apply" forState:UIControlStateNormal];
        });
    });
}

// ── Check if video already set ────────────────────────────────────────────────
- (void)checkExistingVideo {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    NSString *existing = prefs[@"galName"];
    if (existing && [[NSFileManager defaultManager] fileExistsAtPath:existing]) {
        self.selectedVideoURL = [NSURL fileURLWithPath:existing];
        self.statusLabel.text = [existing lastPathComponent];
        self.statusLabel.textColor = COLOR_GREEN;
        self.previewBtn.alpha = 1; self.previewBtn.enabled = YES;
        self.applyBtn.alpha  = 1; self.applyBtn.enabled  = YES;
    }
}

@end
