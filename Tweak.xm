#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// BadgeForge is intentionally implemented without private SpringBoard headers.
// The only private surface we hook is SBIconBadgeView, and all other private
// selectors are resolved dynamically so the project remains easy to build.

static NSString * const BFPreferencesDomain = @"com.joemama383.badgeforge";
#define BFSettingsChangedNotification CFSTR("com.joemama383.badgeforge.settingschanged")
#define BFRespringNotification CFSTR("com.joemama383.badgeforge.respring")

static BOOL BFEnabled = YES;
static NSInteger BFBadgeColorType = 0;   // 0 adaptive, 1 static
static NSInteger BFTextColorType = 1;    // 0 adaptive, 1 static
static BOOL BFBorderEnabled = YES;
static CGFloat BFBorderWidth = 1.0;
static NSInteger BFBorderColorType = 2;  // 0 adaptive, 1 match text, 2 static
static NSString *BFBadgeColorHex = @"#FF0000";
static NSString *BFTextColorHex = @"#FFFFFF";
static NSString *BFBorderColorHex = @"#FFFFFF";

static NSHashTable *BFLiveBadgeViews;
static NSCache *BFDominantColorCache;

@interface BFBadgeSnapshot : NSObject
@property (nonatomic, strong) UIImage *textImage;
@property (nonatomic, strong) UIColor *textTintColor;
@property (nonatomic, strong) UIColor *labelTextColor;
@property (nonatomic, strong) UIImage *backgroundImage;
@property (nonatomic, strong) UIColor *backgroundTintColor;
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, assign) CGFloat borderWidth;
@property (nonatomic, strong) UIColor *borderColor;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, copy) NSString *cornerCurve;
@property (nonatomic, assign) BOOL masksToBounds;
@end
@implementation BFBadgeSnapshot
@end

@interface BFPalette : NSObject
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIColor *borderColor;
@end
@implementation BFPalette
@end

@interface SBIconBadgeView : UIView
@end

static const void *BFIconKey = &BFIconKey;
static const void *BFSnapshotKey = &BFSnapshotKey;
static const void *BFAppliedKey = &BFAppliedKey;

#pragma mark - Preferences

static id BFPreferenceValue(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)BFPreferencesDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)BFPreferencesDomain);
    return CFBridgingRelease(value);
}

static BOOL BFBoolValue(NSString *key, BOOL fallback) {
    id value = BFPreferenceValue(key);
    return value ? [value boolValue] : fallback;
}

static NSInteger BFIntegerValue(NSString *key, NSInteger fallback) {
    id value = BFPreferenceValue(key);
    return value ? [value integerValue] : fallback;
}

static CGFloat BFFloatValue(NSString *key, CGFloat fallback) {
    id value = BFPreferenceValue(key);
    return value ? (CGFloat)[value doubleValue] : fallback;
}

static NSString *BFStringValue(NSString *key, NSString *fallback) {
    id value = BFPreferenceValue(key);
    return [value isKindOfClass:[NSString class]] ? value : fallback;
}

static void BFLoadPreferences(void) {
    BFEnabled = BFBoolValue(@"tweakEnabled", YES);
    BFBadgeColorType = BFIntegerValue(@"badgeColorType", 0);
    BFTextColorType = BFIntegerValue(@"textColorType", 1);
    BFBorderEnabled = BFBoolValue(@"borderEnabled", YES);
    BFBorderWidth = MAX(0.0, MIN(8.0, BFFloatValue(@"borderWidth", 1.0)));
    BFBorderColorType = BFIntegerValue(@"borderColorType", 2);
    BFBadgeColorHex = BFStringValue(@"badgeColor", @"#FF0000");
    BFTextColorHex = BFStringValue(@"textColor", @"#FFFFFF");
    BFBorderColorHex = BFStringValue(@"borderColor", @"#FFFFFF");
}

#pragma mark - Safe private API helpers

static id BFSendObject0(id object, NSString *selectorName) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL BFSendBool1(id object, NSString *selectorName, id argument) {
    if (!object) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(object, selector, argument);
}

static NSInteger BFIntegerFromObject(id value) {
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    return 0;
}

static id BFIvarObject(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(object, ivar);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

#pragma mark - Color utilities

static UIColor *BFColorFromHex(NSString *string, UIColor *fallback) {
    if (![string isKindOfClass:[NSString class]]) return fallback;
    NSString *hex = [[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if ([hex hasPrefix:@"0X"]) hex = [hex substringFromIndex:2];
    if (hex.length != 6 && hex.length != 8) return fallback;

    unsigned long long raw = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexLongLong:&raw]) return fallback;

    CGFloat r, g, b, a;
    if (hex.length == 8) {
        r = ((raw >> 24) & 0xFF) / 255.0;
        g = ((raw >> 16) & 0xFF) / 255.0;
        b = ((raw >> 8) & 0xFF) / 255.0;
        a = (raw & 0xFF) / 255.0;
    } else {
        r = ((raw >> 16) & 0xFF) / 255.0;
        g = ((raw >> 8) & 0xFF) / 255.0;
        b = (raw & 0xFF) / 255.0;
        a = 1.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static CGFloat BFLinearChannel(CGFloat channel) {
    return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);
}

static CGFloat BFRelativeLuminance(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if ([color getWhite:&w alpha:&a]) r = g = b = w;
    }
    return 0.2126 * BFLinearChannel(r) + 0.7152 * BFLinearChannel(g) + 0.0722 * BFLinearChannel(b);
}

static UIColor *BFReadableTextColor(UIColor *background) {
    CGFloat luminance = BFRelativeLuminance(background);
    CGFloat whiteContrast = 1.05 / (luminance + 0.05);
    CGFloat blackContrast = (luminance + 0.05) / 0.05;
    return whiteContrast >= blackContrast ? UIColor.whiteColor : UIColor.blackColor;
}

static UIColor *BFAdaptiveBorderColor(UIColor *background) {
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if ([background getHue:&h saturation:&s brightness:&b alpha:&a]) {
        CGFloat newBrightness = b > 0.58 ? MAX(0.0, b - 0.30) : MIN(1.0, b + 0.34);
        CGFloat newSaturation = MAX(0.18, MIN(1.0, s * 0.92));
        return [UIColor colorWithHue:h saturation:newSaturation brightness:newBrightness alpha:a];
    }
    CGFloat white = 0;
    if ([background getWhite:&white alpha:&a]) {
        white = white > 0.58 ? MAX(0.0, white - 0.30) : MIN(1.0, white + 0.34);
        return [UIColor colorWithWhite:white alpha:a];
    }
    return UIColor.whiteColor;
}

static UIColor *BFDominantColorFromImage(UIImage *image) {
    if (!image) return nil;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;

    const size_t width = 32;
    const size_t height = 32;
    const size_t bytesPerRow = width * 4;
    uint8_t *pixels = calloc(height, bytesPerRow);
    if (!pixels) return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, bytesPerRow,
                                                  colorSpace,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        return nil;
    }

    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    const int binCount = 4096; // 16 bins per RGB channel.
    double *weights = calloc(binCount, sizeof(double));
    double *sumR = calloc(binCount, sizeof(double));
    double *sumG = calloc(binCount, sizeof(double));
    double *sumB = calloc(binCount, sizeof(double));
    if (!weights || !sumR || !sumG || !sumB) {
        free(weights); free(sumR); free(sumG); free(sumB); free(pixels);
        return nil;
    }

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            uint8_t *p = pixels + y * bytesPerRow + x * 4;
            CGFloat r = p[0] / 255.0;
            CGFloat g = p[1] / 255.0;
            CGFloat b = p[2] / 255.0;
            CGFloat a = p[3] / 255.0;
            if (a < 0.20) continue;

            CGFloat maxC = MAX(r, MAX(g, b));
            CGFloat minC = MIN(r, MIN(g, b));
            CGFloat saturation = maxC > 0.001 ? (maxC - minC) / maxC : 0.0;
            CGFloat weight = 0.35 + 2.65 * saturation;

            // Downweight flat white/black icon backgrounds without fully discarding them.
            if ((maxC > 0.95 || maxC < 0.07) && saturation < 0.10) weight *= 0.10;
            weight *= a;

            int ri = MIN(15, (int)floor(r * 16.0));
            int gi = MIN(15, (int)floor(g * 16.0));
            int bi = MIN(15, (int)floor(b * 16.0));
            int index = (ri << 8) | (gi << 4) | bi;
            weights[index] += weight;
            sumR[index] += r * weight;
            sumG[index] += g * weight;
            sumB[index] += b * weight;
        }
    }

    int winner = -1;
    double bestWeight = 0.0;
    for (int i = 0; i < binCount; i++) {
        if (weights[i] > bestWeight) {
            bestWeight = weights[i];
            winner = i;
        }
    }

    UIColor *result = nil;
    if (winner >= 0 && bestWeight > 0.0001) {
        CGFloat r = sumR[winner] / bestWeight;
        CGFloat g = sumG[winner] / bestWeight;
        CGFloat b = sumB[winner] / bestWeight;
        result = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    }

    free(weights); free(sumR); free(sumG); free(sumB); free(pixels);
    return result;
}

#pragma mark - App icon color source

typedef struct {
    CGSize size;
    CGFloat scale;
} BFIconImageInfo;

static id BFEffectiveIcon(id icon) {
    if (!icon) return nil;
    id folder = BFSendObject0(icon, @"folder");
    id icons = BFSendObject0(folder, @"icons");
    if (!icons || ![icons conformsToProtocol:@protocol(NSFastEnumeration)]) return icon;

    id controllerClass = NSClassFromString(@"SBIconController");
    id controller = BFSendObject0(controllerClass, @"sharedInstance");
    id bestIcon = nil;
    NSInteger bestBadge = NSIntegerMin;

    for (id child in icons) {
        if (!child) continue;
        if (controller && [controller respondsToSelector:NSSelectorFromString(@"allowsBadgingForIcon:")] &&
            !BFSendBool1(controller, @"allowsBadgingForIcon:", child)) {
            continue;
        }
        NSInteger badge = BFIntegerFromObject(BFSendObject0(child, @"badgeValue"));
        if (!bestIcon || badge > bestBadge) {
            bestIcon = child;
            bestBadge = badge;
        }
    }
    return bestIcon ?: icon;
}

static NSString *BFIconIdentifier(id icon) {
    id identifier = BFSendObject0(icon, @"nodeIdentifier");
    if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) return identifier;

    identifier = BFSendObject0(icon, @"applicationBundleID");
    if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) return identifier;

    identifier = BFSendObject0(icon, @"bundleIdentifier");
    if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) return identifier;

    return [NSString stringWithFormat:@"%p-%@", icon, NSStringFromClass([icon class])];
}

static UIImage *BFImageForIcon(id icon) {
    if (!icon) return nil;
    SEL selector = NSSelectorFromString(@"generateIconImageWithInfo:");
    if (![icon respondsToSelector:selector]) return nil;

    BFIconImageInfo info;
    info.size = CGSizeMake(60.0, 60.0);
    info.scale = UIScreen.mainScreen.scale;

    typedef UIImage *(*BFImageMessage)(id, SEL, BFIconImageInfo);
    return ((BFImageMessage)objc_msgSend)(icon, selector, info);
}

static UIColor *BFDominantColorForIcon(id originalIcon) {
    id icon = BFEffectiveIcon(originalIcon);
    if (!icon) return nil;
    NSString *cacheKey = BFIconIdentifier(icon);
    UIColor *cached = [BFDominantColorCache objectForKey:cacheKey];
    if (cached) return cached;

    UIImage *image = BFImageForIcon(icon);
    UIColor *dominant = BFDominantColorFromImage(image);
    if (dominant && cacheKey) [BFDominantColorCache setObject:dominant forKey:cacheKey];
    return dominant;
}

static BFPalette *BFPaletteForIcon(id icon) {
    UIColor *adaptiveBackground = BFDominantColorForIcon(icon) ?: [UIColor systemRedColor];
    UIColor *background = BFBadgeColorType == 1
        ? BFColorFromHex(BFBadgeColorHex, [UIColor systemRedColor])
        : adaptiveBackground;

    UIColor *text = BFTextColorType == 1
        ? BFColorFromHex(BFTextColorHex, UIColor.whiteColor)
        : BFReadableTextColor(background);

    UIColor *border;
    switch (BFBorderColorType) {
        case 1:
            border = text;
            break;
        case 2:
            border = BFColorFromHex(BFBorderColorHex, UIColor.whiteColor);
            break;
        case 0:
        default:
            border = BFAdaptiveBorderColor(background);
            break;
    }

    BFPalette *palette = [BFPalette new];
    palette.backgroundColor = background;
    palette.textColor = text;
    palette.borderColor = border;
    return palette;
}

#pragma mark - Badge view theming

static UIView *BFBackgroundView(id badge) {
    id value = BFIvarObject(badge, "_backgroundView");
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

static UIView *BFTextView(id badge) {
    id value = BFIvarObject(badge, "_textView");
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

static BFBadgeSnapshot *BFCaptureSnapshot(id badge) {
    if (!badge) return nil;
    UIView *backgroundView = BFBackgroundView(badge);
    UIView *textView = BFTextView(badge);

    BFBadgeSnapshot *snapshot = [BFBadgeSnapshot new];
    if ([textView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)textView;
        snapshot.textImage = imageView.image;
        snapshot.textTintColor = imageView.tintColor;
    } else if ([textView isKindOfClass:[UILabel class]]) {
        snapshot.labelTextColor = ((UILabel *)textView).textColor;
    }

    if ([backgroundView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)backgroundView;
        snapshot.backgroundImage = imageView.image;
        snapshot.backgroundTintColor = imageView.tintColor;
    }
    snapshot.backgroundColor = backgroundView.backgroundColor;

    CALayer *layer = backgroundView.layer;
    snapshot.borderWidth = layer.borderWidth;
    if (layer.borderColor) snapshot.borderColor = [UIColor colorWithCGColor:layer.borderColor];
    snapshot.cornerRadius = layer.cornerRadius;
    snapshot.masksToBounds = layer.masksToBounds;
    if (@available(iOS 13.0, *)) snapshot.cornerCurve = layer.cornerCurve;

    objc_setAssociatedObject(badge, BFSnapshotKey, snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return snapshot;
}

static void BFRestoreBadge(id badge) {
    if (!badge || ![objc_getAssociatedObject(badge, BFAppliedKey) boolValue]) return;
    BFBadgeSnapshot *snapshot = objc_getAssociatedObject(badge, BFSnapshotKey);
    if (!snapshot) return;

    UIView *backgroundView = BFBackgroundView(badge);
    UIView *textView = BFTextView(badge);

    if ([textView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)textView;
        imageView.image = snapshot.textImage;
        imageView.tintColor = snapshot.textTintColor;
    } else if ([textView isKindOfClass:[UILabel class]]) {
        ((UILabel *)textView).textColor = snapshot.labelTextColor;
    }

    if ([backgroundView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)backgroundView;
        imageView.image = snapshot.backgroundImage;
        imageView.tintColor = snapshot.backgroundTintColor;
    }
    backgroundView.backgroundColor = snapshot.backgroundColor;

    CALayer *layer = backgroundView.layer;
    layer.borderWidth = snapshot.borderWidth;
    layer.borderColor = snapshot.borderColor.CGColor;
    layer.cornerRadius = snapshot.cornerRadius;
    layer.masksToBounds = snapshot.masksToBounds;
    if (@available(iOS 13.0, *)) layer.cornerCurve = snapshot.cornerCurve ?: kCACornerCurveCircular;

    objc_setAssociatedObject(badge, BFAppliedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void BFRegisterBadge(id badge) {
    if (!badge || !BFLiveBadgeViews) return;
    [BFLiveBadgeViews addObject:badge];
}

static void BFApplyBadge(id badge) {
    if (!badge) return;
    if (!BFEnabled) {
        BFRestoreBadge(badge);
        return;
    }

    if (!objc_getAssociatedObject(badge, BFSnapshotKey)) BFCaptureSnapshot(badge);

    UIView *backgroundView = BFBackgroundView(badge);
    UIView *textView = BFTextView(badge);
    if (!backgroundView || !textView) return;

    id icon = objc_getAssociatedObject(badge, BFIconKey);
    BFPalette *palette = BFPaletteForIcon(icon);

    if ([backgroundView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)backgroundView;
        UIImage *image = imageView.image;
        if (image) imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        imageView.tintColor = palette.backgroundColor;
    }
    backgroundView.backgroundColor = palette.backgroundColor;

    if ([textView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)textView;
        UIImage *image = imageView.image;
        if (image) imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        imageView.tintColor = palette.textColor;
    } else if ([textView isKindOfClass:[UILabel class]]) {
        ((UILabel *)textView).textColor = palette.textColor;
    }

    CALayer *layer = backgroundView.layer;
    layer.borderWidth = BFBorderEnabled ? BFBorderWidth : 0.0;
    layer.borderColor = (BFBorderEnabled ? palette.borderColor : UIColor.clearColor).CGColor;
    CGFloat height = CGRectGetHeight(backgroundView.bounds);
    if (height > 0.0) layer.cornerRadius = height * 0.5;
    layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) layer.cornerCurve = kCACornerCurveContinuous;

    objc_setAssociatedObject(badge, BFAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void BFRefreshAllBadges(void) {
    NSArray *badges = BFLiveBadgeViews.allObjects;
    for (id badge in badges) BFApplyBadge(badge);
}

#pragma mark - Notifications

static void BFSettingsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                              const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BFLoadPreferences();
        [BFDominantColorCache removeAllObjects];
        BFRefreshAllBadges();
    });
}

static void BFPerformRespring(CFNotificationCenterRef center, void *observer, CFStringRef name,
                             const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class serviceClass = NSClassFromString(@"FBSystemService");
        SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
        SEL relaunchSelector = NSSelectorFromString(@"exitAndRelaunch:");
        if (serviceClass && [serviceClass respondsToSelector:sharedSelector]) {
            id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, sharedSelector);
            if ([service respondsToSelector:relaunchSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(service, relaunchSelector, YES);
            }
        }
    });
}

#pragma mark - SBIconBadgeView

%hook SBIconBadgeView

- (void)configureForIcon:(id)icon infoProvider:(id)provider {
    BFRestoreBadge(self);
    %orig;
    objc_setAssociatedObject(self, BFIconKey, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BFCaptureSnapshot(self);
    BFRegisterBadge(self);
    BFApplyBadge(self);
}

- (void)configureAnimatedForIcon:(id)icon infoProvider:(id)provider animator:(id)animator {
    BFRestoreBadge(self);
    %orig;
    objc_setAssociatedObject(self, BFIconKey, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BFCaptureSnapshot(self);
    BFRegisterBadge(self);
    BFApplyBadge(self);
}

- (void)_crossfadeToTextImage:(UIImage *)image animator:(id)animator {
    BFRestoreBadge(self);
    %orig;
    BFCaptureSnapshot(self);
    BFApplyBadge(self);
}

- (void)drawRect:(CGRect)rect {
    %orig;
    BFApplyBadge(self);
}

- (void)layoutSubviews {
    %orig;
    BFApplyBadge(self);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        BFRegisterBadge(self);
        BFApplyBadge(self);
    }
}

%end

%ctor {
    @autoreleasepool {
        if (!NSClassFromString(@"SBIconBadgeView")) return;
        BFLiveBadgeViews = [NSHashTable weakObjectsHashTable];
        BFDominantColorCache = [NSCache new];
        BFDominantColorCache.countLimit = 256;
        BFLoadPreferences();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        BFSettingsChanged,
                                        BFSettingsChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        BFPerformRespring,
                                        BFRespringNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        %init;
    }
}
