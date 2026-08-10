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

@interface SBDarkeningImageView : UIImageView
@end

static const void *BFIconKey = &BFIconKey;
static const void *BFPaletteKey = &BFPaletteKey;
static const void *BFSnapshotKey = &BFSnapshotKey;
static const void *BFAppliedKey = &BFAppliedKey;
static const void *BFProbeDumpedKey = &BFProbeDumpedKey;
static const void *BFProbeApplyCountKey = &BFProbeApplyCountKey;

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

static void BFProbeMethodOrigin(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        BFProbeLog(@"method-origin %@ -%@ missing", NSStringFromClass(cls), selectorName);
        return;
    }

    IMP implementation = method_getImplementation(method);
    Dl_info info = {};
    if (implementation && dladdr((const void *)implementation, &info) != 0) {
        NSString *image = info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"<unknown>";
        NSString *symbol = info.dli_sname ? [NSString stringWithUTF8String:info.dli_sname] : @"<unknown>";
        BFProbeLog(@"method-origin %@ -%@ imp=%p image=%@ symbol=%@", NSStringFromClass(cls), selectorName, implementation, image, symbol);
    } else {
        BFProbeLog(@"method-origin %@ -%@ imp=%p image=<unresolved>", NSStringFromClass(cls), selectorName, implementation);
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

    UIImageView *backgroundImageView = [backgroundView isKindOfClass:[UIImageView class]] ? (UIImageView *)backgroundView : nil;
    UIImageView *textImageView = [textView isKindOfClass:[UIImageView class]] ? (UIImageView *)textView : nil;
    BFProbeLog(@"apply badge=%p bgView=%@ textView=%@ palette bg=%@ text=%@ border=%@ width=%.2f",
               badge, NSStringFromClass([backgroundView class]), NSStringFromClass([textView class]),
               BFProbeColorDescription(palette.backgroundColor), BFProbeColorDescription(palette.textColor),
               BFProbeColorDescription(palette.borderColor), BFBorderEnabled ? BFBorderWidth : 0.0);
    BFProbeLog(@"after-write bg.frame=%@ bg.background=%@ bg.tint=%@ bg.image=%@/%@ layer.border=%@/%.2f masks=%d text.image=%@/%@ text.tint=%@",
               NSStringFromCGRect(backgroundView.frame), BFProbeColorDescription(backgroundView.backgroundColor), BFProbeColorDescription(backgroundView.tintColor),
               backgroundImageView.image ? NSStringFromCGSize(backgroundImageView.image.size) : @"<nil>",
               backgroundImageView.image ? @(backgroundImageView.image.renderingMode) : @"<nil>",
               BFProbeCGColorDescription(backgroundView.layer.borderColor), backgroundView.layer.borderWidth, backgroundView.layer.masksToBounds,
               textImageView.image ? NSStringFromCGSize(textImageView.image.size) : @"<nil>",
               textImageView.image ? @(textImageView.image.renderingMode) : @"<nil>", BFProbeColorDescription(textView.tintColor));

    __weak id weakBadge = badge;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongBadge = weakBadge;
        if (!strongBadge) return;
        UIView *bg = BFBackgroundView(strongBadge);
        UIView *txt = BFTextView(strongBadge);
        UIImageView *bgiv = [bg isKindOfClass:[UIImageView class]] ? (UIImageView *)bg : nil;
        UIImageView *txiv = [txt isKindOfClass:[UIImageView class]] ? (UIImageView *)txt : nil;
        BFProbeLog(@"after-80ms badge=%p bg.frame=%@ bg.background=%@ bg.tint=%@ bg.image=%@/%@ layer.border=%@/%.2f masks=%d text.image=%@/%@ text.tint=%@",
                   strongBadge, NSStringFromCGRect(bg.frame), BFProbeColorDescription(bg.backgroundColor), BFProbeColorDescription(bg.tintColor),
                   bgiv.image ? NSStringFromCGSize(bgiv.image.size) : @"<nil>", bgiv.image ? @(bgiv.image.renderingMode) : @"<nil>",
                   BFProbeCGColorDescription(bg.layer.borderColor), bg.layer.borderWidth, bg.layer.masksToBounds,
                   txiv.image ? NSStringFromCGSize(txiv.image.size) : @"<nil>", txiv.image ? @(txiv.image.renderingMode) : @"<nil>",
                   BFProbeColorDescription(txt.tintColor));
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

static BFPalette *BFPaletteForBadge(id badge) {
    if (!badge) return nil;

    BFPalette *palette = objc_getAssociatedObject(badge, BFPaletteKey);
    if (palette) return palette;

    id icon = BFResolveIconForBadge(badge);
    palette = BFPaletteForIcon(icon);
    if (palette) {
        objc_setAssociatedObject(badge, BFPaletteKey, palette, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return palette;
}

static void BFStorePaletteForBadgeAndIcon(id badge, id icon) {
    if (!badge) return;
    if (icon) objc_setAssociatedObject(badge, BFIconKey, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BFPalette *palette = BFPaletteForIcon(icon ?: BFResolveIconForBadge(badge));
    if (palette) {
        objc_setAssociatedObject(badge, BFPaletteKey, palette, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(badge, BFPaletteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIImage *BFColoredTextRaster(UIImage *image, UIColor *color) {
    if (!image || !color) return image;
    if (@available(iOS 13.0, *)) {
        // Bake the requested foreground color into the raster that SpringBoard
        // receives. This survives a later stock tintColor reset to white.
        return [image imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    return image;
}

static void BFUpdateBadgeColors(id badge, UIImage *textImageHint) {
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

    BFPalette *palette = BFPaletteForBadge(badge);
    if (!palette) return;

    // Mirror the stock/Tinge-compatible renderer instead of replacing Apple's
    // badge raster. If SpringBoard has installed a background image, preserve
    // its geometry/mask and make it a template; tintColor then owns its color.
    // backgroundColor is also set as the iOS 17 fallback because freshly
    // created SBDarkeningImageView instances can exist briefly with image=nil.
    if ([backgroundView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)backgroundView;
        UIImage *stockImage = imageView.image;
        if (stockImage && stockImage.renderingMode != UIImageRenderingModeAlwaysTemplate) {
            imageView.image = [stockImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        imageView.tintColor = palette.backgroundColor;
    }
    backgroundView.backgroundColor = palette.backgroundColor;
    backgroundView.tintColor = palette.backgroundColor;

    // The Home Screen can replace _textView's image after app-close animation.
    // Feed it a foreground-colored AlwaysOriginal raster when an incoming image
    // is available so a later stock white tint cannot erase the preference.
    if ([textView isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)textView;
        UIImage *image = textImageHint ?: imageView.image;
        if (image) imageView.image = BFColoredTextRaster(image, palette.textColor);
        imageView.tintColor = palette.textColor;
    } else if ([textView isKindOfClass:[UILabel class]]) {
        ((UILabel *)textView).textColor = palette.textColor;
    }

    CALayer *layer = backgroundView.layer;
    layer.borderWidth = BFBorderEnabled ? BFBorderWidth : 0.0;
    layer.borderColor = (BFBorderEnabled ? palette.borderColor : UIColor.clearColor).CGColor;

    // Stock badge height is 24 pt on the tested iOS 17 layout. Use actual
    // bounds when available and the stock 12 pt radius while it is zero-sized.
    CGFloat height = CGRectGetHeight(backgroundView.bounds);
    layer.cornerRadius = height > 0.0 ? height * 0.5 : 12.0;
    layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) layer.cornerCurve = kCACornerCurveContinuous;

    objc_setAssociatedObject(badge, BFAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BFProbePostApply(badge, palette, backgroundView, textView);
}

static void BFApplyBadgeWithTextImageHint(id badge, UIImage *textImageHint) {
    BFUpdateBadgeColors(badge, textImageHint);
}

static void BFApplyBadge(id badge) {
    BFApplyBadgeWithTextImageHint(badge, nil);
}

static void BFScheduleFinalBadgeReapply(id badge) {
    if (!badge) return;
    __weak id weakBadge = badge;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongBadge = weakBadge;
        if (strongBadge) BFApplyBadge(strongBadge);
    });
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
            objc_setAssociatedObject(badge, BFPaletteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
            BFStorePaletteForBadgeAndIcon(subview, icon);
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

    // Compute/store palette before SpringBoard configures the reusable badge,
    // then perform the final paint after %orig.
    BFStorePaletteForBadgeAndIcon(self, icon);
    objc_setAssociatedObject(self, BFSnapshotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, BFAppliedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    %orig;

    BFCaptureSnapshot(self);
    BFRegisterBadge(self);
    BFUpdateBadgeColors(self, nil);
    BFScheduleFinalBadgeReapply(self);
}

- (void)configureAnimatedForIcon:(id)icon infoProvider:(id)provider animator:(id)animator {
    BFProbeLog(@"HOOK configureAnimated badge=%p class=%@ icon=%p iconClass=%@ provider=%@ animator=%@", self, NSStringFromClass([self class]), icon, NSStringFromClass([icon class]), NSStringFromClass([provider class]), NSStringFromClass([animator class]));

    BFStorePaletteForBadgeAndIcon(self, icon);
    objc_setAssociatedObject(self, BFSnapshotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, BFAppliedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    %orig;

    BFCaptureSnapshot(self);
    BFRegisterBadge(self);
    BFUpdateBadgeColors(self, nil);
    BFScheduleFinalBadgeReapply(self);
}

- (void)_configureAnimatedForText:(NSString *)text highlighted:(BOOL)highlighted animator:(id)animator {
    %orig;
    BFProbeLog(@"HOOK final text configure badge=%p text=%@ highlighted=%d", self, text, highlighted);
    BFUpdateBadgeColors(self, nil);
    BFScheduleFinalBadgeReapply(self);
}

- (void)_crossfadeToTextImage:(UIImage *)image animator:(id)animator {
    BFPalette *palette = BFPaletteForBadge(self);
    UIImage *coloredImage = palette ? BFColoredTextRaster(image, palette.textColor) : image;
    %orig(coloredImage, animator);
    BFUpdateBadgeColors(self, coloredImage);
    BFScheduleFinalBadgeReapply(self);
}

- (void)_zoomInWithTextImage:(UIImage *)image animator:(id)animator {
    BFPalette *palette = BFPaletteForBadge(self);
    UIImage *coloredImage = palette ? BFColoredTextRaster(image, palette.textColor) : image;
    %orig(coloredImage, animator);
    BFUpdateBadgeColors(self, coloredImage);
}

- (void)_resizeForTextImage:(UIImage *)image {
    BFPalette *palette = BFPaletteForBadge(self);
    UIImage *coloredImage = palette ? BFColoredTextRaster(image, palette.textColor) : image;
    %orig(coloredImage);
    BFUpdateBadgeColors(self, coloredImage);
}

- (void)_layOutTextImageView:(UIImageView *)imageView {
    %orig;
    BFUpdateBadgeColors(self, imageView.image);
}

- (void)updateBadgeColors {
    // The probe proves this late refresh selector exists on the user's runtime.
    // Let the existing implementation run, then make BadgeForge the final
    // writer so app-close/Home Screen refresh cannot restore stock red/white.
    %orig;
    BFProbeLog(@"HOOK updateBadgeColors badge=%p", self);
    BFUpdateBadgeColors(self, nil);
}

- (void)drawRect:(CGRect)rect {
    %orig;
    BFUpdateBadgeColors(self, nil);
}

- (void)layoutSubviews {
    %orig;
    BFUpdateBadgeColors(self, nil);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        BFRegisterBadge(self);
        BFUpdateBadgeColors(self, nil);
        BFScheduleFinalBadgeReapply(self);
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
        BFStorePaletteForBadgeAndIcon(badge, icon);
        BFRegisterBadge(badge);
        BFApplyBadge(badge);
    } else {
        BFBindBadgeDescendants(self, icon, 0);
    }
}

%end

%hook SBDarkeningImageView

- (void)setImage:(UIImage *)image {
    id badge = self.superview;
    Class badgeClass = NSClassFromString(@"SBIconBadgeView");
    if (BFEnabled && badgeClass && [badge isKindOfClass:badgeClass]) {
        BFPalette *palette = BFPaletteForBadge(badge);
        UIImage *templateImage = image;
        if (templateImage && templateImage.renderingMode != UIImageRenderingModeAlwaysTemplate) {
            templateImage = [templateImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        %orig(templateImage);
        if (palette) {
            self.tintColor = palette.backgroundColor;
        }
        return;
    }
    %orig;
}

- (void)setBackgroundColor:(UIColor *)color {
    id badge = self.superview;
    Class badgeClass = NSClassFromString(@"SBIconBadgeView");
    if (BFEnabled && badgeClass && [badge isKindOfClass:badgeClass]) {
        BFPalette *palette = BFPaletteForBadge(badge);
        if (palette) {
            %orig(palette.backgroundColor);
            return;
        }
    }
    %orig;
}

- (void)setTintColor:(UIColor *)color {
    id badge = self.superview;
    Class badgeClass = NSClassFromString(@"SBIconBadgeView");
    if (BFEnabled && badgeClass && [badge isKindOfClass:badgeClass]) {
        BFPalette *palette = BFPaletteForBadge(badge);
        if (palette) {
            %orig(palette.backgroundColor);
            return;
        }
    }
    %orig;
}

%end

%hook UIImageView

- (void)setImage:(UIImage *)image {
    UIView *background = self.superview;
    UIView *badge = background.superview;
    Class darkeningClass = NSClassFromString(@"SBDarkeningImageView");
    Class badgeClass = NSClassFromString(@"SBIconBadgeView");

    // _textView is a plain UIImageView nested inside the badge's
    // SBDarkeningImageView. Intercept the exact late image replacement that
    // occurs when the Home Screen returns from an app, but leave every other
    // UIImageView in SpringBoard untouched.
    if (BFEnabled && darkeningClass && badgeClass &&
        [background isKindOfClass:darkeningClass] &&
        [badge isKindOfClass:badgeClass]) {
        BFPalette *palette = BFPaletteForBadge(badge);
        UIImage *coloredImage = palette ? BFColoredTextRaster(image, palette.textColor) : image;
        %orig(coloredImage);
        if (palette) self.tintColor = palette.textColor;
        return;
    }

    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (!NSClassFromString(@"SBIconBadgeView")) return;
        BFProbeLog(@"\n\n===== BadgeForge 1.0.13 probe start iOS=%@ process=%@ SBIconBadgeView=%@ =====", UIDevice.currentDevice.systemVersion, NSProcessInfo.processInfo.processName, NSClassFromString(@"SBIconBadgeView"));
        BFProbeJailbreakEnvironment();
        BFProbeDiscoverBadgeClasses();
        Class badgeClass = NSClassFromString(@"SBIconBadgeView");
        for (NSString *selectorName in @[ @"updateBadgeColors", @"getBadgeColorsForIcon:", @"tingeColors", @"setTingeColors:" ]) {
            BFProbeMethodOrigin(badgeClass, selectorName);
        }
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
