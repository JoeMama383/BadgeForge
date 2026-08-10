#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdlib.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <stdarg.h>
#import <mach-o/dyld.h>

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
static id BFBadgeColorRaw = nil;
static id BFTextColorRaw = nil;
static id BFBorderColorRaw = nil;

static const char *BFProbePath = "/var/mobile/BadgeForgeProbe.log";
static const NSUInteger BFProbeBadgeLimit = 12;
static NSUInteger BFProbeBadgeCount = 0;
static void *BFColorPickerHandle = NULL;
typedef UIColor *(*BFLCPParseColorStringFunction)(NSString *, NSString *);
static BFLCPParseColorStringFunction BFLCPParseColorString = NULL;

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
static const void *BFProbeDumpedKey = &BFProbeDumpedKey;
static const void *BFProbeApplyCountKey = &BFProbeApplyCountKey;
static const void *BFFillLayerKey = &BFFillLayerKey;

#pragma mark - Probe logging

static NSString *BFProbeObjectDescription(id value) {
    if (!value) return @"<nil>";
    NSString *desc = nil;
    @try { desc = [value description]; } @catch (__unused NSException *exception) { desc = @"<description threw>"; }
    return [NSString stringWithFormat:@"%@(%@)", NSStringFromClass([value class]), desc ?: @"<nil>"];
}

static NSString *BFProbeColorDescription(UIColor *color) {
    if (!color) return @"<nil>";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"rgba(%.3f,%.3f,%.3f,%.3f)", r, g, b, a];
    }
    CGFloat w = 0;
    if ([color getWhite:&w alpha:&a]) {
        return [NSString stringWithFormat:@"white(%.3f,%.3f)", w, a];
    }
    return [color description];
}

static NSString *BFProbeCGColorDescription(CGColorRef color) {
    if (!color) return @"<nil>";
    return BFProbeColorDescription([UIColor colorWithCGColor:color]);
}

static void BFProbeLog(NSString *format, ...) {
    if (!format) return;
    struct stat info;
    if (stat(BFProbePath, &info) == 0 && info.st_size > (1024 * 1024)) unlink(BFProbePath);

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(BFProbePath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        if (data.length) (void)write(fd, data.bytes, data.length);
        close(fd);
    }
}

static BOOL BFProbeRelevantName(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    NSArray<NSString *> *tokens = @[ @"badge", @"background", @"foreground", @"color", @"fill", @"text", @"label", @"image", @"tint", @"layer", @"icon", @"material" ];
    for (NSString *token in tokens) if ([lower containsString:token]) return YES;
    return NO;
}

static void BFProbeDumpRelevantIvars(id object) {
    if (!object) return;
    for (Class cls = object_getClass(object); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivar) ?: ""];
            if (!BFProbeRelevantName(name)) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (type && type[0] == '@') {
                id value = nil;
                @try { value = object_getIvar(object, ivar); } @catch (__unused NSException *exception) {}
                BFProbeLog(@"ivar %@.%@ type=%s value=%@", NSStringFromClass(cls), name, type, BFProbeObjectDescription(value));
            } else {
                BFProbeLog(@"ivar %@.%@ type=%s", NSStringFromClass(cls), name, type ?: "?");
            }
        }
        free(ivars);
    }
}

static void BFProbeDumpRelevantMethods(Class cls) {
    NSUInteger emitted = 0;
    for (Class cur = cls; cur && cur != [UIView class] && emitted < 100; cur = class_getSuperclass(cur)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cur, &count);
        for (unsigned int i = 0; i < count && emitted < 100; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if (!BFProbeRelevantName(name) && ![name.lowercaseString containsString:@"configure"] && ![name.lowercaseString containsString:@"layout"] && ![name.lowercaseString containsString:@"update"]) continue;
            BFProbeLog(@"method %@ -%@", NSStringFromClass(cur), name);
            emitted++;
        }
        free(methods);
    }
}

static void BFProbeDumpLayer(CALayer *layer, NSUInteger depth) {
    if (!layer || depth > 4) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    BFProbeLog(@"%@layer %@ %p frame=%@ bg=%@ border=%@/%.2f corner=%.2f opacity=%.2f hidden=%d contents=%p",
               indent, NSStringFromClass([layer class]), layer, NSStringFromCGRect(layer.frame),
               BFProbeCGColorDescription(layer.backgroundColor), BFProbeCGColorDescription(layer.borderColor), layer.borderWidth,
               layer.cornerRadius, layer.opacity, layer.hidden, (__bridge void *)layer.contents);
    if ([layer isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        BFProbeLog(@"%@  shape fill=%@ stroke=%@ lineWidth=%.2f path=%p", indent,
                   BFProbeCGColorDescription(shape.fillColor), BFProbeCGColorDescription(shape.strokeColor), shape.lineWidth, (void *)shape.path);
    }
    if ([layer isKindOfClass:[CAGradientLayer class]]) {
        CAGradientLayer *gradient = (CAGradientLayer *)layer;
        BFProbeLog(@"%@  gradient colors=%@", indent, gradient.colors);
    }
    for (CALayer *child in [layer.sublayers copy]) BFProbeDumpLayer(child, depth + 1);
}

static void BFProbeDumpView(UIView *view, NSUInteger depth) {
    if (!view || depth > 4) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    BFProbeLog(@"%@view %@ %p frame=%@ alpha=%.2f hidden=%d bg=%@ tint=%@",
               indent, NSStringFromClass([view class]), view, NSStringFromCGRect(view.frame), view.alpha, view.hidden,
               BFProbeColorDescription(view.backgroundColor), BFProbeColorDescription(view.tintColor));
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        BFProbeLog(@"%@  label text=%@ color=%@", indent, label.text, BFProbeColorDescription(label.textColor));
    }
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)view;
        BFProbeLog(@"%@  image=%p size=%@ mode=%ld tint=%@", indent, iv.image, NSStringFromCGSize(iv.image.size),
                   (long)iv.image.renderingMode, BFProbeColorDescription(iv.tintColor));
    }
    BFProbeDumpLayer(view.layer, depth);
    for (UIView *child in view.subviews) BFProbeDumpView(child, depth + 1);
}

static void BFProbeDiscoverBadgeClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = static_cast<Class *>(calloc((size_t)count, sizeof(Class)));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"badge"] && ([lower containsString:@"icon"] || [lower containsString:@"springboard"])) {
            BFProbeLog(@"runtime badge class: %@ superclass=%@", name, NSStringFromClass(class_getSuperclass(classes[i])));
        }
    }
    free(classes);
}

static void BFProbeJailbreakEnvironment(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *paths = @[
        @"/var/jb",
        @"/var/jb/usr/lib/libellekit.dylib",
        @"/var/jb/usr/lib/libsubstrate.dylib",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/var/jb/usr/lib/libcolorpicker.dylib"
    ];
    NSMutableArray<NSString *> *states = [NSMutableArray array];
    for (NSString *path in paths) {
        BOOL isDirectory = NO;
        BOOL exists = [fm fileExistsAtPath:path isDirectory:&isDirectory];
        [states addObject:[NSString stringWithFormat:@"%@=%d%s", path, exists, (exists && isDirectory) ? "(dir)" : ""]];
    }
    BFProbeLog(@"jailbreak env uid=%u euid=%u rootlessPaths=%@", getuid(), geteuid(), states);

    NSMutableArray<NSString *> *interestingImages = [NSMutableArray array];
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *cname = _dyld_get_image_name(i);
        if (!cname) continue;
        NSString *name = [NSString stringWithUTF8String:cname];
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"ellekit"] || [lower containsString:@"substrate"] ||
            [lower containsString:@"dopamine"] || [lower containsString:@"nathan"] ||
            [lower containsString:@"hooker"] || [lower containsString:@"badgeforge"] ||
            [lower containsString:@"colorpicker"]) {
            [interestingImages addObject:name];
        }
    }
    BFProbeLog(@"loaded jailbreak/hook images=%@", interestingImages);
}

#pragma mark - Preferences

static id BFCFPreferenceValue(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)BFPreferencesDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)BFPreferencesDomain);
    return CFBridgingRelease(value);
}

static id BFDirectPreferenceValue(NSString *key, NSString **sourcePath) {
    // libcolorpicker is legacy code and on Dopamine/ElleKit can persist its
    // color strings by writing the preference plist directly instead of
    // going through cfprefsd. Read both rootless and canonical locations so
    // those writes are visible to SpringBoard immediately.
    NSArray<NSString *> *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.joemama383.badgeforge.plist",
        @"/var/mobile/Library/Preferences/com.joemama383.badgeforge.plist"
    ];
    for (NSString *path in paths) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        id value = [dict isKindOfClass:[NSDictionary class]] ? dict[key] : nil;
        if (value) {
            if (sourcePath) *sourcePath = path;
            return value;
        }
    }
    return nil;
}

static id BFPreferenceValue(NSString *key) {
    return BFCFPreferenceValue(key);
}

static id BFColorPreferenceValue(NSString *key, NSString *fallback) {
    NSString *path = nil;
    id fileValue = BFDirectPreferenceValue(key, &path);
    if (fileValue) {
        BFProbeLog(@"color pref %@ source=direct-plist path=%@ value=%@", key, path, BFProbeObjectDescription(fileValue));
        return fileValue;
    }

    id cfValue = BFCFPreferenceValue(key);
    if (cfValue) {
        BFProbeLog(@"color pref %@ source=CFPreferences value=%@", key, BFProbeObjectDescription(cfValue));
        return cfValue;
    }
    BFProbeLog(@"color pref %@ source=fallback value=%@", key, fallback);
    return fallback;
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

static void BFLoadPreferences(void) {
    BFEnabled = BFBoolValue(@"tweakEnabled", YES);
    BFBadgeColorType = BFIntegerValue(@"badgeColorType", 0);
    BFTextColorType = BFIntegerValue(@"textColorType", 1);
    BFBorderEnabled = BFBoolValue(@"borderEnabled", YES);
    BFBorderWidth = MAX(0.0, MIN(8.0, BFFloatValue(@"borderWidth", 1.0)));
    BFBorderColorType = BFIntegerValue(@"borderColorType", 2);
    BFBadgeColorRaw = BFColorPreferenceValue(@"badgeColor", @"#FF0000");
    BFTextColorRaw = BFColorPreferenceValue(@"textColor", @"#FFFFFF");
    BFBorderColorRaw = BFColorPreferenceValue(@"borderColor", @"#FFFFFF");
    BFProbeLog(@"prefs enabled=%d badgeType=%ld textType=%ld borderEnabled=%d borderWidth=%.3f borderType=%ld badgeRaw=%@ textRaw=%@ borderRaw=%@",
               BFEnabled, (long)BFBadgeColorType, (long)BFTextColorType, BFBorderEnabled, BFBorderWidth, (long)BFBorderColorType,
               BFProbeObjectDescription(BFBadgeColorRaw), BFProbeObjectDescription(BFTextColorRaw), BFProbeObjectDescription(BFBorderColorRaw));
}

#pragma mark - Safe private API helpers

static id BFSendObject0(id object, NSString *selectorName) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGSize BFSendSize0(id object, NSString *selectorName) {
    if (!object) return CGSizeZero;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return CGSizeZero;
    return ((CGSize (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGSize BFSendSize1(id object, NSString *selectorName, id argument) {
    if (!object) return CGSizeZero;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return CGSizeZero;
    return ((CGSize (*)(id, SEL, id))objc_msgSend)(object, selector, argument);
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

static void BFLoadColorPickerParser(void) {
    if (BFLCPParseColorString) return;
    const char *paths[] = { "/var/jb/usr/lib/libcolorpicker.dylib", "/usr/lib/libcolorpicker.dylib" };
    for (NSUInteger i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *handle = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (!handle) continue;
        void *symbol = dlsym(handle, "LCPParseColorString");
        if (symbol) {
            BFColorPickerHandle = handle;
            BFLCPParseColorString = reinterpret_cast<BFLCPParseColorStringFunction>(symbol);
            BFProbeLog(@"libcolorpicker parser loaded from %s symbol=%p", paths[i], symbol);
            return;
        }
    }
    BFProbeLog(@"libcolorpicker parser unavailable");
}

static UIColor *BFColorFromPickerValue(id raw, NSString *fallbackString, UIColor *fallbackColor) {
    if ([raw isKindOfClass:[UIColor class]]) return (UIColor *)raw;
    NSString *value = [raw isKindOfClass:[NSString class]] ? (NSString *)raw : nil;
    BFLoadColorPickerParser();
    if (value && BFLCPParseColorString) {
        UIColor *parsed = nil;
        @try { parsed = BFLCPParseColorString(value, fallbackString); } @catch (__unused NSException *exception) {}
        if ([parsed isKindOfClass:[UIColor class]]) {
            BFProbeLog(@"picker parse raw=%@ fallback=%@ -> %@", value, fallbackString, BFProbeColorDescription(parsed));
            return parsed;
        }
    }
    UIColor *fallbackParsed = BFColorFromHex(value ?: fallbackString, fallbackColor);
    BFProbeLog(@"picker fallback parse raw=%@ -> %@", BFProbeObjectDescription(raw), BFProbeColorDescription(fallbackParsed));
    return fallbackParsed;
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
    BFProbeLog(@"bundle image request bundle=%@ format=%ld scale=%.2f selector1=%d", bundleIdentifier, (long)format, scale, [imageClass respondsToSelector:selector]);
    if ([imageClass respondsToSelector:selector]) {
        typedef UIImage *(*BFBundleImageMessage)(id, SEL, NSString *, NSInteger, CGFloat);
        UIImage *image = ((BFBundleImageMessage)objc_msgSend)(imageClass, selector,
                                                              bundleIdentifier, format, scale);
        if (image && image.CGImage) { BFProbeLog(@"bundle image selector1 success size=%@", NSStringFromCGSize(image.size)); return image; }
    }

    selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:roleIdentifier:format:scale:");
    if ([imageClass respondsToSelector:selector]) {
        typedef UIImage *(*BFRoleBundleImageMessage)(id, SEL, NSString *, id, NSInteger, CGFloat);
        UIImage *image = ((BFRoleBundleImageMessage)objc_msgSend)(imageClass, selector,
                                                                  bundleIdentifier, nil, format, scale);
        if (image && image.CGImage) { BFProbeLog(@"bundle image selector2 success size=%@", NSStringFromCGSize(image.size)); return image; }
    }
    BFProbeLog(@"bundle image failed bundle=%@", bundleIdentifier);
    return nil;
}

static UIImage *BFGeneratedImageForIcon(id icon) {
    if (!icon) return nil;
    SEL selector = NSSelectorFromString(@"generateIconImageWithInfo:");
    if (![icon respondsToSelector:selector]) { BFProbeLog(@"icon %@ does not respond generateIconImageWithInfo:", NSStringFromClass([icon class])); return nil; }

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
    BFProbeLog(@"generated icon image class=%@ result=%p size=%@", NSStringFromClass([icon class]), image, NSStringFromCGSize(image.size));
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

    NSString *bundleID = BFBundleIdentifierForIcon(icon);
    BFProbeLog(@"adaptive icon=%p class=%@ bundle=%@ cacheKey=%@", icon, NSStringFromClass([icon class]), bundleID, cacheKey);
    UIImage *image = BFImageForIcon(icon);
    UIColor *average = BFAverageColorFromImage(image);
    BFProbeLog(@"adaptive image=%p size=%@ average=%@", image, NSStringFromCGSize(image.size), BFProbeColorDescription(average));
    if (average && cacheKey) [BFAdaptiveColorCache setObject:average forKey:cacheKey];
    return average;
}
static BFPalette *BFPaletteForIcon(id icon) {
    UIColor *adaptiveBackground = BFAdaptiveColorForIcon(icon) ?: [UIColor systemRedColor];
    UIColor *background = BFBadgeColorType == 1
        ? BFColorFromPickerValue(BFBadgeColorRaw, @"#FF0000", [UIColor systemRedColor])
        : adaptiveBackground;

    UIColor *text = BFTextColorType == 1
        ? BFColorFromPickerValue(BFTextColorRaw, @"#FFFFFF", UIColor.whiteColor)
        : BFReadableTextColor(background);

    UIColor *border;
    switch (BFBorderColorType) {
        case 1:
            border = text;
            break;
        case 2:
            border = BFColorFromPickerValue(BFBorderColorRaw, @"#FFFFFF", UIColor.whiteColor);
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

static UIView *BFBackgroundView(id badge);
static UIView *BFTextView(id badge);

static void BFProbeDumpBadge(id badge, id icon) {
    if (!badge || [objc_getAssociatedObject(badge, BFProbeDumpedKey) boolValue]) return;
    if (BFProbeBadgeCount >= BFProbeBadgeLimit) return;
    BFProbeBadgeCount++;
    objc_setAssociatedObject(badge, BFProbeDumpedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BFProbeLog(@"===== BADGE SNAPSHOT %lu badge=%p class=%@ super=%@ icon=%p iconClass=%@ bundle=%@ =====",
               (unsigned long)BFProbeBadgeCount, badge, NSStringFromClass([badge class]), NSStringFromClass(class_getSuperclass([badge class])),
               icon, icon ? NSStringFromClass([icon class]) : @"<nil>", BFBundleIdentifierForIcon(icon));
    BFProbeDumpRelevantMethods([badge class]);
    BFProbeDumpRelevantIvars(badge);

    UIView *view = [badge isKindOfClass:[UIView class]] ? (UIView *)badge : nil;
    NSMutableArray *chain = [NSMutableArray array];
    for (UIView *cur = view; cur && chain.count < 8; cur = cur.superview) [chain addObject:NSStringFromClass([cur class])];
    BFProbeLog(@"superview chain=%@", chain);
    BFProbeDumpView(view, 0);
}

static void BFProbePostApply(id badge, BFPalette *palette, UIView *backgroundView, UIView *textView) {
    NSUInteger applyCount = [objc_getAssociatedObject(badge, BFProbeApplyCountKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(badge, BFProbeApplyCountKey, @(applyCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (applyCount > 3) return;
    BFProbeLog(@"apply badge=%p bgView=%@ textView=%@ palette bg=%@ text=%@ border=%@ width=%.2f",
               badge, NSStringFromClass([backgroundView class]), NSStringFromClass([textView class]),
               BFProbeColorDescription(palette.backgroundColor), BFProbeColorDescription(palette.textColor),
               BFProbeColorDescription(palette.borderColor), BFBorderEnabled ? BFBorderWidth : 0.0);
    CALayer *fillLayer = objc_getAssociatedObject(backgroundView, BFFillLayerKey);
    BFProbeLog(@"after-write bg.background=%@ bg.tint=%@ layer.bg=%@ fill.bg=%@ fill.frame=%@ layer.border=%@/%.2f text.background=%@ text.tint=%@",
               BFProbeColorDescription(backgroundView.backgroundColor), BFProbeColorDescription(backgroundView.tintColor),
               BFProbeCGColorDescription(backgroundView.layer.backgroundColor), BFProbeCGColorDescription(fillLayer.backgroundColor), NSStringFromCGRect(fillLayer.frame),
               BFProbeCGColorDescription(backgroundView.layer.borderColor), backgroundView.layer.borderWidth,
               BFProbeColorDescription(textView.backgroundColor), BFProbeColorDescription(textView.tintColor));

    __weak id weakBadge = badge;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongBadge = weakBadge;
        if (!strongBadge) return;
        UIView *bg = BFBackgroundView(strongBadge);
        UIView *txt = BFTextView(strongBadge);
        CALayer *fillLayer = objc_getAssociatedObject(bg, BFFillLayerKey);
        BFProbeLog(@"after-80ms badge=%p bgClass=%@ bg.background=%@ bg.tint=%@ layer.bg=%@ fill.bg=%@ fill.frame=%@ layer.border=%@/%.2f textClass=%@ text.background=%@ text.tint=%@",
                   strongBadge, NSStringFromClass([bg class]), BFProbeColorDescription(bg.backgroundColor), BFProbeColorDescription(bg.tintColor),
                   BFProbeCGColorDescription(bg.layer.backgroundColor), BFProbeCGColorDescription(fillLayer.backgroundColor), NSStringFromCGRect(fillLayer.frame),
                   BFProbeCGColorDescription(bg.layer.borderColor), bg.layer.borderWidth,
                   NSStringFromClass([txt class]), BFProbeColorDescription(txt.backgroundColor), BFProbeColorDescription(txt.tintColor));
    });
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

    CALayer *fillLayer = objc_getAssociatedObject(backgroundView, BFFillLayerKey);
    if (fillLayer) {
        [fillLayer removeFromSuperlayer];
        objc_setAssociatedObject(backgroundView, BFFillLayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

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

static BOOL BFUsableBadgeSize(CGSize size) {
    return isfinite(size.width) && isfinite(size.height) && size.width > 0.5 && size.height > 0.5;
}

static CGSize BFResolvedBadgeSize(id badge, UIView *backgroundView, UIView *textView) {
    CGSize size = backgroundView.bounds.size;
    if (BFUsableBadgeSize(size)) return size;

    if ([badge isKindOfClass:[UIView class]]) {
        size = ((UIView *)badge).bounds.size;
        if (BFUsableBadgeSize(size)) return size;
    }

    // iOS 17 exposes the final stock badge size even during transitions where
    // _backgroundView still temporarily reports a 0x0 bounds rectangle.
    size = BFSendSize0(badge, @"badgeSize");
    if (BFUsableBadgeSize(size)) return size;

    if ([textView isKindOfClass:[UIImageView class]]) {
        UIImage *textImage = ((UIImageView *)textView).image;
        if (textImage) {
            size = BFSendSize1(badge, @"intrinsicContentSizeForTextImage:", textImage);
            if (BFUsableBadgeSize(size)) return size;
        }
    }

    return CGSizeZero;
}

static void BFSyncFillGeometry(id badge) {
    UIView *backgroundView = BFBackgroundView(badge);
    UIView *textView = BFTextView(badge);
    if (!backgroundView) return;

    CALayer *fillLayer = objc_getAssociatedObject(backgroundView, BFFillLayerKey);
    if (!fillLayer) return;

    CGSize size = BFResolvedBadgeSize(badge, backgroundView, textView);
    if (!BFUsableBadgeSize(size)) return;

    BOOL backgroundHasRealBounds = BFUsableBadgeSize(backgroundView.bounds.size);
    BOOL geometryChanged = !CGSizeEqualToSize(fillLayer.frame.size, size);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    fillLayer.frame = (CGRect){ CGPointZero, size };
    CGFloat radius = size.height * 0.5;
    fillLayer.cornerRadius = radius;
    fillLayer.masksToBounds = YES;

    // When SpringBoard has not sized SBDarkeningImageView yet, do not let its
    // temporary 0x0 bounds clip our already-known stock badge dimensions.
    // Once the real bounds arrive the ordinary layout hook restores clipping.
    backgroundView.layer.masksToBounds = backgroundHasRealBounds;
    if (@available(iOS 13.0, *)) fillLayer.cornerCurve = kCACornerCurveContinuous;
    [CATransaction commit];

    if (geometryChanged) {
        BFProbeLog(@"fill-geometry badge=%p bg.bounds=%@ badge.bounds=%@ resolved=%@ source=%@",
                   badge, NSStringFromCGRect(backgroundView.bounds),
                   [badge isKindOfClass:[UIView class]] ? NSStringFromCGRect(((UIView *)badge).bounds) : @"<nonview>",
                   NSStringFromCGSize(size), backgroundHasRealBounds ? @"background" : @"badgeSize-fallback");
    }
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
    BFProbeDumpBadge(badge, icon);
    BFPalette *palette = BFPaletteForIcon(icon);

    // iOS 17's SBDarkeningImageView paints the stock red badge through its
    // image/layer contents. backgroundColor and tintColor can both change
    // successfully while that opaque stock image remains visible. Put a
    // dedicated solid layer above the image contents but below _textView so
    // static and adaptive backgrounds actually become the visible badge fill.
    CALayer *fillLayer = objc_getAssociatedObject(backgroundView, BFFillLayerKey);
    if (!fillLayer) {
        fillLayer = [CALayer layer];
        fillLayer.name = @"BadgeForgeFill";
        [backgroundView.layer insertSublayer:fillLayer atIndex:0];
        objc_setAssociatedObject(backgroundView, BFFillLayerKey, fillLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (fillLayer.superlayer != backgroundView.layer) {
        [backgroundView.layer insertSublayer:fillLayer atIndex:0];
    }

    fillLayer.backgroundColor = palette.backgroundColor.CGColor;
    fillLayer.opacity = 1.0;
    fillLayer.hidden = NO;

    // Tinge recolors the stock raster itself by forcing UIImage rendering into
    // template mode. Doing the same here is more reliable than relying only on
    // an overlay layer: Home Screen badges can have a temporarily 0x0
    // SBDarkeningImageView while their stock image is being configured.
    if ([backgroundView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)backgroundView;
        UIImage *image = imageView.image;
        if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
            imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        imageView.tintColor = palette.backgroundColor;
    }

    // Keep these synchronized as well for transitions and any SpringBoard
    // code that samples the view's own tint/background properties.
    backgroundView.backgroundColor = palette.backgroundColor;
    backgroundView.tintColor = palette.backgroundColor;

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
    if (@available(iOS 13.0, *)) layer.cornerCurve = kCACornerCurveContinuous;

    BFSyncFillGeometry(badge);

    objc_setAssociatedObject(badge, BFAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BFProbePostApply(badge, palette, backgroundView, textView);
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
        for (id badge in BFLiveBadgeViews.allObjects) {
            objc_setAssociatedObject(badge, BFProbeApplyCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        BFProbeLog(@"settingschanged: cleared adaptive cache and per-badge apply probe counters");
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
    BFProbeLog(@"HOOK configureForIcon badge=%p class=%@ icon=%p iconClass=%@ provider=%@", self, NSStringFromClass([self class]), icon, NSStringFromClass([icon class]), NSStringFromClass([provider class]));
    BFRestoreBadge(self);
    %orig;
    objc_setAssociatedObject(self, BFIconKey, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BFCaptureSnapshot(self);
    BFRegisterBadge(self);
    BFApplyBadge(self);
}

- (void)configureAnimatedForIcon:(id)icon infoProvider:(id)provider animator:(id)animator {
    BFProbeLog(@"HOOK configureAnimated badge=%p class=%@ icon=%p iconClass=%@ provider=%@ animator=%@", self, NSStringFromClass([self class]), icon, NSStringFromClass([icon class]), NSStringFromClass([provider class]), NSStringFromClass([animator class]));
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

- (void)_resizeForTextImage:(UIImage *)image {
    %orig;
    BFSyncFillGeometry(self);
}

- (void)_layOutTextImageView:(UIImageView *)imageView {
    %orig;
    BFSyncFillGeometry(self);
}

- (void)drawRect:(CGRect)rect {
    %orig;
    BFApplyBadge(self);
}

- (void)layoutSubviews {
    %orig;
    BFApplyBadge(self);
    BFSyncFillGeometry(self);
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
        BFProbeLog(@"\n\n===== BadgeForge 1.0.10 probe start iOS=%@ process=%@ SBIconBadgeView=%@ =====", UIDevice.currentDevice.systemVersion, NSProcessInfo.processInfo.processName, NSClassFromString(@"SBIconBadgeView"));
        BFProbeJailbreakEnvironment();
        BFProbeDiscoverBadgeClasses();
        BFLoadColorPickerParser();
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
