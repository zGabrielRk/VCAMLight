// VCAMOverlay.mm
// VCAMLight — Premium overlay UI inspired by LordVCAM's aesthetic.
// Dark theme, green neon accents, glassmorphism cards, login system.

#import "VCAMOverlay.h"
#import <AVFoundation/AVFoundation.h>

// ── Forward declarations for PhotosUI ─────────────────────────────────────────
@interface PHPickerResult : NSObject
@property (nonatomic, strong, readonly) NSItemProvider *itemProvider;
@end

@interface PHPickerFilter : NSObject
+ (PHPickerFilter *)videosFilter;
@end

@interface PHPickerConfiguration : NSObject
@property (nonatomic, copy) PHPickerFilter *filter;
@property (nonatomic, assign) NSInteger selectionLimit;
- (instancetype)init;
@end

@interface PHPickerViewController : UIViewController
- (instancetype)initWithConfiguration:(PHPickerConfiguration *)configuration;
@property (nonatomic, weak) id delegate;
@end

@protocol PHPickerViewControllerDelegate <NSObject>
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results;
@end

// ── Paths & notification keys ─────────────────────────────────────────────────
static NSString *const kPrefsPath  = @"/var/tmp/com.vcamlight.cache/prefs.plist";
static NSString *const kVideoPath  = @"/var/tmp/com.vcamlight.cache/selected.mov";
static NSString *const kDarwinNote = @"com.vcamlight.videochanged";
static NSString *const kLoginNote  = @"com.vcamlight.loginchanged";

// Login endpoint (your own backend)
static NSString *const kLoginURL   = @"https://vcamlight-api.example.com/auth/login";
static NSString *const kVerifyURL  = @"https://vcamlight-api.example.com/auth/verify";

// ── Colors — LordVCAM-inspired dark theme ─────────────────────────────────────
#define CLR_BG           [UIColor colorWithRed:0.043 green:0.051 blue:0.067 alpha:1.0]
#define CLR_CARD         [UIColor colorWithRed:0.059 green:0.067 blue:0.090 alpha:0.95]
#define CLR_CARD_BORDER  [UIColor colorWithRed:0.15 green:0.17 blue:0.22 alpha:0.6]
#define CLR_GREEN        [UIColor colorWithRed:0.157 green:0.780 blue:0.435 alpha:1.0]
#define CLR_GREEN_DK     [UIColor colorWithRed:0.10 green:0.55 blue:0.30 alpha:1.0]
#define CLR_GOLD         [UIColor colorWithRed:0.973 green:0.757 blue:0.176 alpha:1.0]
#define CLR_TEXT         [UIColor colorWithRed:0.91 green:0.92 blue:0.94 alpha:1.0]
#define CLR_MUTED        [UIColor colorWithRed:0.45 green:0.47 blue:0.55 alpha:1.0]
#define CLR_INPUT_BG     [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:1.0]
#define CLR_INPUT_BORDER [UIColor colorWithRed:0.18 green:0.20 blue:0.25 alpha:1.0]
#define CLR_RED          [UIColor colorWithRed:0.95 green:0.30 blue:0.30 alpha:1.0]
#define CLR_OVERLAY_BG   [UIColor colorWithRed:0.0 green:0.0 blue:0.02 alpha:0.75]

// ── Internal interface ────────────────────────────────────────────────────────
@interface VCAMOverlay () <PHPickerViewControllerDelegate>

// Window & navigation
@property (nonatomic, strong) UIWindow      *overlayWindow;
@property (nonatomic, strong) UIView        *loginCard;
@property (nonatomic, strong) UIView        *mainCard;

// Login UI
@property (nonatomic, strong) UITextField   *emailField;
@property (nonatomic, strong) UITextField   *passwordField;
@property (nonatomic, strong) UIButton      *loginBtn;
@property (nonatomic, strong) UILabel       *loginErrorLabel;
@property (nonatomic, strong) UIActivityIndicatorView *loginSpinner;

// Main UI
@property (nonatomic, strong) UIView        *previewContainer;
@property (nonatomic, strong) AVPlayer      *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) UILabel       *previewLabel;
@property (nonatomic, strong) UILabel       *statusLabel;
@property (nonatomic, strong) UILabel       *userLabel;
@property (nonatomic, strong) UIButton      *selectBtn;
@property (nonatomic, strong) UIButton      *previewBtn;
@property (nonatomic, strong) UIButton      *applyBtn;
@property (nonatomic, strong) UIButton      *stopBtn;
@property (nonatomic, strong) UIButton      *logoutBtn;

// State
@property (nonatomic, strong) NSURL         *selectedVideoURL;
@property (nonatomic, assign) BOOL          applied;
@property (nonatomic, assign) BOOL          loggedIn;
@property (nonatomic, copy)   NSString      *sessionToken;
@property (nonatomic, copy)   NSString      *userEmail;
@end

@implementation VCAMOverlay

+ (instancetype)shared {
    static VCAMOverlay *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [VCAMOverlay new]; });
    return inst;
}

// ── Toggle show/hide ──────────────────────────────────────────────────────────
+ (void)toggle {
    VCAMOverlay *ov = [self shared];
    if (ov.overlayWindow && !ov.overlayWindow.hidden) {
        [ov performHide];
    } else {
        [ov performShow];
    }
}

+ (void)show  { [[self shared] performShow]; }
+ (void)hide  { [[self shared] performHide]; }

// ── Show ──────────────────────────────────────────────────────────────────────
- (void)performShow {
    if (!self.overlayWindow) [self buildWindow];

    // Decide which card to show
    [self loadSession];
    self.loginCard.hidden = self.loggedIn;
    self.mainCard.hidden  = !self.loggedIn;

    dispatch_async(dispatch_get_main_queue(), ^{
        self.overlayWindow.hidden = NO;

        UIView *activeCard = self.loggedIn ? self.mainCard : self.loginCard;
        activeCard.transform = CGAffineTransformMakeTranslation(0, 60);
        activeCard.alpha = 0;

        [UIView animateWithDuration:0.4
                              delay:0
             usingSpringWithDamping:0.75
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            activeCard.transform = CGAffineTransformIdentity;
            activeCard.alpha = 1;
        } completion:nil];
    });
}

// ── Hide ──────────────────────────────────────────────────────────────────────
- (void)performHide {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *activeCard = self.loggedIn ? self.mainCard : self.loginCard;
        [UIView animateWithDuration:0.25
                         animations:^{
            activeCard.transform = CGAffineTransformMakeTranslation(0, 50);
            activeCard.alpha = 0;
        } completion:^(BOOL done) {
            self.overlayWindow.hidden = YES;
            activeCard.transform = CGAffineTransformIdentity;
        }];
    });
}

// ── Build window ──────────────────────────────────────────────────────────────
- (void)buildWindow {
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
    self.overlayWindow.backgroundColor = CLR_OVERLAY_BG;

    // Tap backdrop to dismiss
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(backdropTapped:)];
    tap.cancelsTouchesInView = NO;
    [self.overlayWindow addGestureRecognizer:tap];

    // Root VC
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow.rootViewController = root;

    // Build both cards
    [self buildLoginCard];
    [self buildMainCard];

    self.overlayWindow.hidden = YES;
}

// ══════════════════════════════════════════════════════════════════════════════
// ═══ LOGIN CARD ══════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════

- (void)buildLoginCard {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat cardW = MIN(sw - 40, 340);
    CGFloat cardH = 380;
    CGFloat cardX = (sw - cardW) / 2;
    CGFloat cardY = (sh - cardH) / 2;

    self.loginCard = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    self.loginCard.backgroundColor = CLR_CARD;
    self.loginCard.layer.cornerRadius = 20;
    self.loginCard.layer.borderWidth = 1;
    self.loginCard.layer.borderColor = [CLR_CARD_BORDER CGColor];
    self.loginCard.layer.masksToBounds = YES;

    // ── Logo area ──
    // Crown icon (emoji as placeholder — real app would use image)
    UILabel *crownIcon = [[UILabel alloc] initWithFrame:CGRectMake(0, 28, cardW, 30)];
    crownIcon.text = @"📷 👑";
    crownIcon.font = [UIFont systemFontOfSize:22];
    crownIcon.textAlignment = NSTextAlignmentCenter;
    [self.loginCard addSubview:crownIcon];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 60, cardW, 24)];
    titleLabel.text = @"VCAMLight";
    titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    titleLabel.textColor = CLR_GOLD;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.loginCard addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 86, cardW, 16)];
    subtitleLabel.text = @"Virtual Camera for iOS";
    subtitleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    subtitleLabel.textColor = CLR_MUTED;
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.loginCard addSubview:subtitleLabel];

    // ── Separator ──
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(24, 114, cardW - 48, 1)];
    sep.backgroundColor = CLR_CARD_BORDER;
    [self.loginCard addSubview:sep];

    // ── Email field ──
    UILabel *emailLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 126, cardW - 48, 16)];
    emailLabel.text = @"E-mail";
    emailLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    emailLabel.textColor = CLR_MUTED;
    [self.loginCard addSubview:emailLabel];

    self.emailField = [[UITextField alloc] initWithFrame:CGRectMake(24, 146, cardW - 48, 44)];
    [self styleTextField:self.emailField placeholder:@"seu@email.com"];
    self.emailField.keyboardType = UIKeyboardTypeEmailAddress;
    self.emailField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.loginCard addSubview:self.emailField];

    // ── Password field ──
    UILabel *passLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 200, cardW - 48, 16)];
    passLabel.text = @"Senha";
    passLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    passLabel.textColor = CLR_MUTED;
    [self.loginCard addSubview:passLabel];

    self.passwordField = [[UITextField alloc] initWithFrame:CGRectMake(24, 220, cardW - 48, 44)];
    [self styleTextField:self.passwordField placeholder:@"••••••••"];
    self.passwordField.secureTextEntry = YES;
    [self.loginCard addSubview:self.passwordField];

    // ── Error label ──
    self.loginErrorLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 272, cardW - 48, 16)];
    self.loginErrorLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.loginErrorLabel.textColor = CLR_RED;
    self.loginErrorLabel.textAlignment = NSTextAlignmentCenter;
    self.loginErrorLabel.hidden = YES;
    [self.loginCard addSubview:self.loginErrorLabel];

    // ── Login button ──
    self.loginBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.loginBtn.frame = CGRectMake(24, 296, cardW - 48, 48);
    self.loginBtn.backgroundColor = CLR_GREEN;
    self.loginBtn.layer.cornerRadius = 12;
    self.loginBtn.layer.masksToBounds = YES;
    [self.loginBtn setTitle:@"Entrar" forState:UIControlStateNormal];
    [self.loginBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    self.loginBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [self.loginBtn addTarget:self action:@selector(loginTapped)
            forControlEvents:UIControlEventTouchUpInside];
    [self addPressAnimation:self.loginBtn];
    [self.loginCard addSubview:self.loginBtn];

    // ── Spinner ──
    self.loginSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loginSpinner.center = CGPointMake(cardW / 2, 320);
    self.loginSpinner.color = CLR_GREEN;
    self.loginSpinner.hidesWhenStopped = YES;
    [self.loginCard addSubview:self.loginSpinner];

    // ── Support link ──
    UIButton *supportBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    supportBtn.frame = CGRectMake(24, 350, cardW - 48, 18);
    [supportBtn setTitle:@"Suporte" forState:UIControlStateNormal];
    [supportBtn setTitleColor:[UIColor colorWithRed:0.45 green:0.65 blue:0.95 alpha:1]
                     forState:UIControlStateNormal];
    supportBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [self.loginCard addSubview:supportBtn];

    // ── Close X ──
    [self addCloseButton:self.loginCard width:cardW];

    [self.overlayWindow addSubview:self.loginCard];
}

// ══════════════════════════════════════════════════════════════════════════════
// ═══ MAIN CARD (after login) ════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════

- (void)buildMainCard {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat cardW = MIN(sw - 40, 360);
    CGFloat cardH = 530;
    CGFloat cardX = (sw - cardW) / 2;
    CGFloat cardY = (sh - cardH) / 2;

    self.mainCard = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    self.mainCard.backgroundColor = CLR_CARD;
    self.mainCard.layer.cornerRadius = 20;
    self.mainCard.layer.borderWidth = 1;
    self.mainCard.layer.borderColor = [CLR_CARD_BORDER CGColor];
    self.mainCard.layer.masksToBounds = YES;

    // ── Green top accent line ──
    UIView *accent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, 2)];
    accent.backgroundColor = CLR_GREEN;
    [self.mainCard addSubview:accent];

    // ── Header: Logo + user info ──
    UILabel *logo = [[UILabel alloc] initWithFrame:CGRectMake(20, 14, 140, 20)];
    logo.text = @"📷 VCAMLight";
    logo.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    logo.textColor = CLR_GOLD;
    [self.mainCard addSubview:logo];

    self.userLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 34, cardW - 100, 14)];
    self.userLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    self.userLabel.textColor = CLR_MUTED;
    [self.mainCard addSubview:self.userLabel];

    // ── Logout button ──
    self.logoutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.logoutBtn.frame = CGRectMake(cardW - 76, 16, 56, 28);
    [self.logoutBtn setTitle:@"Sair" forState:UIControlStateNormal];
    [self.logoutBtn setTitleColor:CLR_RED forState:UIControlStateNormal];
    self.logoutBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    self.logoutBtn.backgroundColor = [UIColor colorWithRed:0.95 green:0.30 blue:0.30 alpha:0.1];
    self.logoutBtn.layer.cornerRadius = 8;
    [self.logoutBtn addTarget:self action:@selector(logoutTapped)
             forControlEvents:UIControlEventTouchUpInside];
    [self.mainCard addSubview:self.logoutBtn];

    // ── Preview area ──
    CGFloat prevH = 190;
    self.previewContainer = [[UIView alloc] initWithFrame:CGRectMake(16, 58, cardW - 32, prevH)];
    self.previewContainer.backgroundColor = CLR_INPUT_BG;
    self.previewContainer.layer.cornerRadius = 14;
    self.previewContainer.layer.borderWidth = 1;
    self.previewContainer.layer.borderColor = [CLR_INPUT_BORDER CGColor];
    self.previewContainer.layer.masksToBounds = YES;
    [self.mainCard addSubview:self.previewContainer];

    self.previewLabel = [[UILabel alloc] initWithFrame:self.previewContainer.bounds];
    self.previewLabel.text = @"Preview do Vídeo";
    self.previewLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.previewLabel.textColor = CLR_MUTED;
    self.previewLabel.textAlignment = NSTextAlignmentCenter;
    [self.previewContainer addSubview:self.previewLabel];

    // ── Status label ──
    CGFloat bY = 58 + prevH + 10;
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, bY, cardW - 40, 16)];
    self.statusLabel.text = @"Nenhum vídeo selecionado";
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.statusLabel.textColor = CLR_MUTED;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.mainCard addSubview:self.statusLabel];

    // ── Select / Preview buttons row ──
    CGFloat btnY = bY + 26;
    CGFloat btnW = (cardW - 48) / 2;
    CGFloat btnH = 48;

    self.selectBtn = [self makePrimaryButton:@"Selecionar"
                                      frame:CGRectMake(16, btnY, btnW, btnH)
                                     action:@selector(selectTapped)];
    [self.mainCard addSubview:self.selectBtn];

    self.previewBtn = [self makeOutlineButton:@"Preview"
                                       frame:CGRectMake(16 + btnW + 16, btnY, btnW, btnH)
                                      action:@selector(previewTapped)];
    self.previewBtn.alpha = 0.4;
    self.previewBtn.enabled = NO;
    [self.mainCard addSubview:self.previewBtn];

    // ── Apply button ──
    self.applyBtn = [self makePrimaryButton:@"Aplicar à Câmera"
                                     frame:CGRectMake(16, btnY + btnH + 12, cardW - 32, 52)
                                    action:@selector(applyTapped)];
    self.applyBtn.alpha = 0.4;
    self.applyBtn.enabled = NO;
    [self.mainCard addSubview:self.applyBtn];

    // ── Stop button ──
    self.stopBtn = [self makeOutlineButton:@"Parar Câmera Virtual"
                                    frame:CGRectMake(16, btnY + btnH + 12 + 52 + 10,
                                                     cardW - 32, 44)
                                   action:@selector(stopTapped)];
    self.stopBtn.hidden = YES;
    [self.mainCard addSubview:self.stopBtn];

    // ── Status indicator ──
    UIView *statusDot = [[UIView alloc] initWithFrame:CGRectMake(16, cardH - 28, 6, 6)];
    statusDot.backgroundColor = CLR_GREEN;
    statusDot.layer.cornerRadius = 3;
    statusDot.tag = 999;
    [self.mainCard addSubview:statusDot];

    UILabel *versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, cardH - 32, 200, 14)];
    versionLabel.text = @"VCAMLight v1.0 — Ativo";
    versionLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    versionLabel.textColor = CLR_MUTED;
    [self.mainCard addSubview:versionLabel];

    // ── Close X ──
    [self addCloseButton:self.mainCard width:cardW];

    [self.overlayWindow addSubview:self.mainCard];

    // Check if already applied
    [self checkExistingVideo];
}

// ══════════════════════════════════════════════════════════════════════════════
// ═══ UI HELPERS ══════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════

- (void)styleTextField:(UITextField *)tf placeholder:(NSString *)ph {
    tf.backgroundColor = CLR_INPUT_BG;
    tf.layer.cornerRadius = 10;
    tf.layer.borderWidth = 1;
    tf.layer.borderColor = [CLR_INPUT_BORDER CGColor];
    tf.textColor = CLR_TEXT;
    tf.font = [UIFont systemFontOfSize:14];
    tf.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:ph
        attributes:@{NSForegroundColorAttributeName: [CLR_MUTED colorWithAlphaComponent:0.5]}];

    // Padding
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 44)];
    tf.leftView = pad;
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 44)];
    tf.rightViewMode = UITextFieldViewModeAlways;
}

- (UIButton *)makePrimaryButton:(NSString *)title frame:(CGRect)frame action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = CLR_GREEN;
    btn.layer.cornerRadius = 12;
    btn.layer.masksToBounds = YES;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    if (action) {
        [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }
    [self addPressAnimation:btn];
    return btn;
}

- (UIButton *)makeOutlineButton:(NSString *)title frame:(CGRect)frame action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = [UIColor clearColor];
    btn.layer.cornerRadius = 12;
    btn.layer.borderWidth = 1.5;
    btn.layer.borderColor = [CLR_CARD_BORDER CGColor];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:CLR_TEXT forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    if (action) {
        [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }
    [self addPressAnimation:btn];
    return btn;
}

- (void)addPressAnimation:(UIButton *)btn {
    [btn addTarget:self action:@selector(btnDown:)
  forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [btn addTarget:self action:@selector(btnUp:)
  forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchCancel |
                   UIControlEventTouchDragExit | UIControlEventTouchUpOutside];
}

- (void)addCloseButton:(UIView *)card width:(CGFloat)w {
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(w - 42, 10, 32, 32);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:CLR_MUTED forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [closeBtn addTarget:self action:@selector(performHide)
       forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];
}

- (void)btnDown:(UIButton *)b {
    [UIView animateWithDuration:0.1 animations:^{
        b.transform = CGAffineTransformMakeScale(0.96, 0.96);
        b.alpha = 0.85;
    }];
}

- (void)btnUp:(UIButton *)b {
    [UIView animateWithDuration:0.2 animations:^{
        b.transform = CGAffineTransformIdentity;
        b.alpha = b.enabled ? 1.0 : 0.4;
    }];
}

- (void)backdropTapped:(UITapGestureRecognizer *)gesture {
    CGPoint loc = [gesture locationInView:self.overlayWindow];
    UIView *activeCard = self.loggedIn ? self.mainCard : self.loginCard;
    if (!CGRectContainsPoint(activeCard.frame, loc)) {
        [self performHide];
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// ═══ LOGIN LOGIC ═════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════

- (void)loginTapped {
    NSString *email = self.emailField.text;
    NSString *password = self.passwordField.text;

    if (email.length == 0 || password.length == 0) {
        [self showLoginError:@"Preencha todos os campos"];
        return;
    }

    // Show loading state
    self.loginBtn.hidden = YES;
    [self.loginSpinner startAnimating];
    self.loginErrorLabel.hidden = YES;

    // Make login request to your backend
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL success = [self performLoginWithEmail:email password:password];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loginSpinner stopAnimating];
            self.loginBtn.hidden = NO;

            if (success) {
                [self onLoginSuccess:email];
            } else {
                [self showLoginError:@"Credenciais inválidas ou erro de conexão"];
            }
        });
    });
}

- (BOOL)performLoginWithEmail:(NSString *)email password:(NSString *)password {
    @try {
        // Build request
        NSURL *url = [NSURL URLWithString:kLoginURL];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 15;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        NSDictionary *body = @{@"email": email, @"password": password};
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

        __block BOOL success = NO;
        __block NSString *token = nil;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (!error && data) {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                        options:0
                                                                          error:nil];
                    if ([json[@"success"] boolValue]) {
                        token = json[@"token"];
                        success = YES;
                    }
                }
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));

        if (success && token) {
            self.sessionToken = token;
            return YES;
        }

        // Fallback: If server unreachable, allow offline login for development
        // Remove this in production!
        #if DEBUG
        return YES;
        #endif

        return NO;
    } @catch (NSException *e) {
        return NO;
    }
}

- (void)onLoginSuccess:(NSString *)email {
    self.loggedIn = YES;
    self.userEmail = email;
    [self saveSession];

    // Animate transition from login to main card
    [UIView animateWithDuration:0.25 animations:^{
        self.loginCard.transform = CGAffineTransformMakeScale(0.95, 0.95);
        self.loginCard.alpha = 0;
    } completion:^(BOOL done) {
        self.loginCard.hidden = YES;
        self.loginCard.transform = CGAffineTransformIdentity;

        self.mainCard.hidden = NO;
        self.mainCard.transform = CGAffineTransformMakeTranslation(0, 40);
        self.mainCard.alpha = 0;

        self.userLabel.text = [NSString stringWithFormat:@"Logado: %@", email];

        [UIView animateWithDuration:0.35
                              delay:0
             usingSpringWithDamping:0.78
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.mainCard.transform = CGAffineTransformIdentity;
            self.mainCard.alpha = 1;
        } completion:nil];
    }];
}

- (void)showLoginError:(NSString *)msg {
    self.loginErrorLabel.text = msg;
    self.loginErrorLabel.hidden = NO;

    // Shake animation
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    shake.values = @[@(-8), @(8), @(-6), @(6), @(-3), @(3), @(0)];
    shake.duration = 0.4;
    [self.loginCard.layer addAnimation:shake forKey:@"shake"];
}

- (void)logoutTapped {
    self.loggedIn = NO;
    self.sessionToken = nil;
    self.userEmail = nil;
    [self clearSession];

    // Stop any active replacement
    [self stopReplacement];

    // Transition back to login
    [UIView animateWithDuration:0.2 animations:^{
        self.mainCard.alpha = 0;
    } completion:^(BOOL done) {
        self.mainCard.hidden = YES;
        self.loginCard.hidden = NO;
        self.loginCard.alpha = 0;
        self.loginCard.transform = CGAffineTransformMakeTranslation(0, 30);

        [UIView animateWithDuration:0.3 animations:^{
            self.loginCard.alpha = 1;
            self.loginCard.transform = CGAffineTransformIdentity;
        }];
    }];
}

// ── Session persistence ───────────────────────────────────────────────────────

- (void)saveSession {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
        ?: [NSMutableDictionary new];
    prefs[@"loggedIn"] = @YES;
    prefs[@"userEmail"] = self.userEmail ?: @"";
    prefs[@"sessionToken"] = self.sessionToken ?: @"";
    [prefs writeToFile:kPrefsPath atomically:YES];
}

- (void)loadSession {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    self.loggedIn = [prefs[@"loggedIn"] boolValue];
    self.userEmail = prefs[@"userEmail"];
    self.sessionToken = prefs[@"sessionToken"];

    if (self.loggedIn && self.userEmail) {
        self.userLabel.text = [NSString stringWithFormat:@"Logado: %@", self.userEmail];
    }
}

- (void)clearSession {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
        ?: [NSMutableDictionary new];
    [prefs removeObjectForKey:@"loggedIn"];
    [prefs removeObjectForKey:@"userEmail"];
    [prefs removeObjectForKey:@"sessionToken"];
    [prefs writeToFile:kPrefsPath atomically:YES];
}

// ══════════════════════════════════════════════════════════════════════════════
// ═══ CAMERA ACTIONS ══════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════

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

- (void)stopTapped {
    [self stopReplacement];
}

// ── PHPickerViewControllerDelegate ────────────────────────────────────────────
- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    PHPickerResult *result = results.firstObject;
    NSString *typeId = nil;
    if ([result.itemProvider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        typeId = @"public.movie";
    } else if ([result.itemProvider hasItemConformingToTypeIdentifier:@"public.video"]) {
        typeId = @"public.video";
    }
    if (!typeId) return;

    [result.itemProvider loadFileRepresentationForTypeIdentifier:typeId
                                              completionHandler:^(NSURL *url, NSError *err) {
        if (!url) return;

        // Ensure cache directory exists
        [[NSFileManager defaultManager]
            createDirectoryAtPath:@"/var/tmp/com.vcamlight.cache"
            withIntermediateDirectories:YES
            attributes:nil error:nil];

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
            self.statusLabel.text = [NSString stringWithFormat:@"🎬 %@", name];
            self.statusLabel.textColor = CLR_GREEN;
            self.previewBtn.alpha = 1;
            self.previewBtn.enabled = YES;
            self.applyBtn.alpha = 1;
            self.applyBtn.enabled = YES;
            [self startPreview:stableURL];
        });
    }];
}

// ── Preview ───────────────────────────────────────────────────────────────────
- (void)startPreview:(NSURL *)url {
    if (self.playerLayer) [self.playerLayer removeFromSuperlayer];
    self.player = [AVPlayer playerWithURL:url];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:self.player.currentItem queue:nil
        usingBlock:^(NSNotification *n) {
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
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
        ?: [NSMutableDictionary new];
    prefs[@"replOn"]  = @YES;
    prefs[@"loopOn"]  = @YES;
    prefs[@"galName"] = url.path;
    prefs[@"mode"]    = @"gallery";
    [prefs writeToFile:kPrefsPath atomically:YES];

    // Notify all hooked processes
    notify_post([kDarwinNote UTF8String]);

    // Visual feedback
    [UIView animateWithDuration:0.25 animations:^{
        self.applyBtn.backgroundColor = CLR_GREEN;
        [self.applyBtn setTitle:@"✓ Aplicado!" forState:UIControlStateNormal];
    }];
    self.applied = YES;
    self.stopBtn.hidden = NO;

    // Pulse animation on status dot
    UIView *dot = [self.mainCard viewWithTag:999];
    [UIView animateWithDuration:0.5
                          delay:0
                        options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat
                     animations:^{
        dot.alpha = 0.3;
    } completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.applyBtn setTitle:@"Aplicar à Câmera" forState:UIControlStateNormal];
    });
}

// ── Stop ──────────────────────────────────────────────────────────────────────
- (void)stopReplacement {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
        ?: [NSMutableDictionary new];
    prefs[@"replOn"] = @NO;
    [prefs writeToFile:kPrefsPath atomically:YES];

    notify_post([kDarwinNote UTF8String]);

    self.applied = NO;
    self.stopBtn.hidden = YES;

    // Reset status dot
    UIView *dot = [self.mainCard viewWithTag:999];
    [dot.layer removeAllAnimations];
    dot.alpha = 1.0;
    dot.backgroundColor = CLR_MUTED;
}

// ── Check existing video ──────────────────────────────────────────────────────
- (void)checkExistingVideo {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    NSString *existing = prefs[@"galName"];
    if (existing && [[NSFileManager defaultManager] fileExistsAtPath:existing]) {
        self.selectedVideoURL = [NSURL fileURLWithPath:existing];
        self.statusLabel.text = [NSString stringWithFormat:@"🎬 %@",
            [existing lastPathComponent]];
        self.statusLabel.textColor = CLR_GREEN;
        self.previewBtn.alpha = 1;
        self.previewBtn.enabled = YES;
        self.applyBtn.alpha = 1;
        self.applyBtn.enabled = YES;
    }
    if ([prefs[@"replOn"] boolValue]) {
        self.applied = YES;
        self.stopBtn.hidden = NO;
    }
}

@end
