#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdlib.h>

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
static NSCache *BFAdaptiveColorCache;

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

@interface SBIconView : UIView
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

static UIColor *BFAverageColorFromImage(UIImage *image) {
    if (!image) return nil;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;

    // A small raster is plenty for a badge color and keeps SpringBoard work bounded.
    const size_t width = 40;
    const size_t height = 40;
    const size_t bytesPerRow = width * 4;
    uint8_t *pixels = static_cast<uint8_t *>(calloc(height, bytesPerRow));
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

    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    double weightedR = 0.0, weightedG = 0.0, weightedB = 0.0, totalWeight = 0.0;
    double fallbackR = 0.0, fallbackG = 0.0, fallbackB = 0.0, fallbackWeight = 0.0;

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            uint8_t *pixel = pixels + y * bytesPerRow + x * 4;
            CGFloat alpha = pixel[3] / 255.0;
            if (alpha < 0.08) continue;

            // The bitmap is premultiplied. Un-premultiply before averaging so
            // partially transparent antialiasing pixels do not skew toward black.
            CGFloat r = MIN(1.0, (pixel[0] / 255.0) / alpha);
            CGFloat g = MIN(1.0, (pixel[1] / 255.0) / alpha);
            CGFloat b = MIN(1.0, (pixel[2] / 255.0) / alpha);

            fallbackR += r * alpha;
            fallbackG += g * alpha;
            fallbackB += b * alpha;
            fallbackWeight += alpha;

            CGFloat maxC = MAX(r, MAX(g, b));
            CGFloat minC = MIN(r, MIN(g, b));
            CGFloat saturation = maxC > 0.001 ? (maxC - minC) / maxC : 0.0;

            // This is still an average, not a single winning histogram bin. Give
            // chromatic pixels more influence so white/black icon backgrounds do
            // not wash a colorful app icon down to grey.
            CGFloat weight = alpha * (0.35 + 1.65 * saturation);
            if (saturation < 0.08 && (maxC > 0.94 || maxC < 0.08)) weight *= 0.18;

            weightedR += r * weight;
            weightedG += g * weight;
            weightedB += b * weight;
            totalWeight += weight;
        }
    }

    UIColor *result = nil;
    if (totalWeight > 0.0001) {
        result = [UIColor colorWithRed:weightedR / totalWeight
                                 green:weightedG / totalWeight
                                  blue:weightedB / totalWeight
                                 alpha:1.0];
    } else if (fallbackWeight > 0.0001) {
        result = [UIColor colorWithRed:fallbackR / fallbackWeight
                                 green:fallbackG / fallbackWeight
                                  blue:fallbackB / fallbackWeight
                                 alpha:1.0];
    }

    free(pixels);
    return result;
}
#pragma mark - App icon color source

typedef struct {
    CGSize size;
    CGFloat scale;
    CGFloat continuousCornerRadius;
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

static NSString *BFBundleIdentifierForIcon(id icon) {
    if (!icon) return nil;

    NSArray<NSString *> *directSelectors = @[
        @"applicationBundleID",
        @"bundleIdentifier",
        @"applicationBundleIdentifier"
    ];
    for (NSString *selectorName in directSelectors) {
        id value = BFSendObject0(icon, selectorName);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }

    // iOS has moved the bundle identifier between the icon and its application
    // object over time, so follow the common ownership objects dynamically.
    NSArray<NSString *> *ownerSelectors = @[
        @"application",
        @"applicationProxy",
        @"applicationInfo"
    ];
    for (NSString *ownerSelector in ownerSelectors) {
        id owner = BFSendObject0(icon, ownerSelector);
        if (!owner) continue;
        for (NSString *selectorName in directSelectors) {
            id value = BFSendObject0(owner, selectorName);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
        }
    }

    // nodeIdentifier is commonly the bundle id for application icons. Only use
    // it as a final fallback when it looks bundle-id-like, never for folders.
    id nodeIdentifier = BFSendObject0(icon, @"nodeIdentifier");
    if ([nodeIdentifier isKindOfClass:[NSString class]]) {
        NSString *node = (NSString *)nodeIdentifier;
        if ([node rangeOfString:@"."].location != NSNotFound &&
            [node rangeOfString:@"folder" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            return node;
        }
    }
    return nil;
}

static UIImage *BFImageForBundleIdentifier(NSString *bundleIdentifier) {
    if (![bundleIdentifier isKindOfClass:[NSString class]] || bundleIdentifier.length == 0) return nil;

    Class imageClass = [UIImage class];
    CGFloat scale = UIScreen.mainScreen.scale;
    NSInteger format = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 8 : 10;

    // This UIKit private entry point remains used by modern jailbreak tooling and
    // avoids depending on SBIcon's older generateIconImageWithInfo: implementation.
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([imageClass respondsToSelector:selector]) {
        typedef UIImage *(*BFBundleImageMessage)(id, SEL, NSString *, NSInteger, CGFloat);
        UIImage *image = ((BFBundleImageMessage)objc_msgSend)(imageClass, selector,
                                                              bundleIdentifier, format, scale);
        if (image && image.CGImage) return image;
    }

    selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:roleIdentifier:format:scale:");
    if ([imageClass respondsToSelector:selector]) {
        typedef UIImage *(*BFRoleBundleImageMessage)(id, SEL, NSString *, id, NSInteger, CGFloat);
        UIImage *image = ((BFRoleBundleImageMessage)objc_msgSend)(imageClass, selector,
                                                                  bundleIdentifier, nil, format, scale);
        if (image && image.CGImage) return image;
    }
    return nil;
}

static UIImage *BFGeneratedImageForIcon(id icon) {
    if (!icon) return nil;
    SEL selector = NSSelectorFromString(@"generateIconImageWithInfo:");
    if (![icon respondsToSelector:selector]) return nil;

    // SBIconImageInfo is three CGFloat-sized fields on modern iOS.  The previous
    // BadgeForge build omitted continuousCornerRadius, so the private method was
    // called with the wrong ABI/struct size and commonly returned no usable icon.
    BFIconImageInfo info;
    info.size = CGSizeMake(60.0, 60.0);
    info.scale = UIScreen.mainScreen.scale;
    info.continuousCornerRadius = 12.0;

    typedef UIImage *(*BFImageMessage)(id, SEL, BFIconImageInfo);
    UIImage *image = nil;
    @try {
        image = ((BFImageMessage)objc_msgSend)(icon, selector, info);
    } @catch (__unused NSException *exception) {
        image = nil;
    }
    return (image && image.CGImage) ? image : nil;
}

static UIImage *BFImageForIcon(id icon) {
    // Prefer SpringBoard's own SBIcon renderer.  It is the same icon object that
    // owns this badge and therefore also works for themed/alternate app icons.
    UIImage *image = BFGeneratedImageForIcon(icon);
    if (image) return image;

    // Keep the UIKit bundle-id renderer as a secondary path for application icons
    // whose SBIcon renderer is temporarily unavailable during hydration.
    NSString *bundleIdentifier = BFBundleIdentifierForIcon(icon);
    return BFImageForBundleIdentifier(bundleIdentifier);
}

static id BFResolveIconForBadge(id badge) {
    if (!badge) return nil;

    id icon = objc_getAssociatedObject(badge, BFIconKey);
    if (icon) return icon;

    // Some iOS 17 badge refresh paths call layout/draw without re-running the
    // configureForIcon: hook. Recover the owning icon from the badge/icon-view
    // hierarchy instead of silently falling back to stock red.
    NSArray<NSString *> *selectors = @[ @"icon", @"representedIcon" ];
    for (NSString *selectorName in selectors) {
        icon = BFSendObject0(badge, selectorName);
        if (icon) break;
    }
    if (!icon) icon = BFIvarObject(badge, "_icon");
    if (!icon) icon = BFIvarObject(badge, "_representedIcon");

    UIView *view = [badge isKindOfClass:[UIView class]] ? (UIView *)badge : nil;
    for (NSUInteger depth = 0; !icon && view && depth < 10; depth++, view = view.superview) {
        for (NSString *selectorName in selectors) {
            icon = BFSendObject0(view, selectorName);
            if (icon) break;
        }
        if (!icon) icon = BFIvarObject(view, "_icon");
        if (!icon) icon = BFIvarObject(view, "_representedIcon");
    }

    if (icon) objc_setAssociatedObject(badge, BFIconKey, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return icon;
}

static UIColor *BFAdaptiveColorForIcon(id originalIcon) {
    id icon = BFEffectiveIcon(originalIcon);
    if (!icon) return nil;

    NSString *cacheKey = BFIconIdentifier(icon);
    UIColor *cached = [BFAdaptiveColorCache objectForKey:cacheKey];
    if (cached) return cached;

    UIImage *image = BFImageForIcon(icon);
    UIColor *average = BFAverageColorFromImage(image);
    if (average && cacheKey) [BFAdaptiveColorCache setObject:average forKey:cacheKey];
    return average;
}
static BFPalette *BFPaletteForIcon(id icon) {
    UIColor *adaptiveBackground = BFAdaptiveColorForIcon(icon) ?: [UIColor systemRedColor];
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

    id icon = BFResolveIconForBadge(badge);
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
        [BFAdaptiveColorCache removeAllObjects];
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

static void BFBindBadgeDescendants(UIView *root, id icon, NSUInteger depth) {
    if (!root || !icon || depth > 5) return;
    Class badgeClass = NSClassFromString(@"SBIconBadgeView");
    if (!badgeClass) return;

    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:badgeClass]) {
            objc_setAssociatedObject(subview, BFIconKey, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BFRegisterBadge(subview);
            BFApplyBadge(subview);
            continue;
        }
        BFBindBadgeDescendants(subview, icon, depth + 1);
    }
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

%hook SBIconView

- (void)layoutSubviews {
    %orig;
    id icon = BFSendObject0(self, @"icon");
    if (!icon) icon = BFIvarObject(self, "_icon");
    if (!icon) return;

    id badge = BFIvarObject(self, "_badgeView");
    if ([badge isKindOfClass:NSClassFromString(@"SBIconBadgeView")]) {
        objc_setAssociatedObject(badge, BFIconKey, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BFRegisterBadge(badge);
        BFApplyBadge(badge);
    } else {
        BFBindBadgeDescendants(self, icon, 0);
    }
}

%end

%ctor {
    @autoreleasepool {
        if (!NSClassFromString(@"SBIconBadgeView")) return;
        BFLiveBadgeViews = [NSHashTable weakObjectsHashTable];
        BFAdaptiveColorCache = [NSCache new];
        BFAdaptiveColorCache.countLimit = 256;
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
