#import "BFRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

#define BFRespringNotification CFSTR("com.joemama383.badgeforge.respring")

static NSString * const BFPreferencesDomain = @"com.joemama383.badgeforge";

static void BFEnsureColorPickerLoaded(void) {
    if (NSClassFromString(@"PFSimpleLiteColorCell")) return;

    const char *paths[] = {
        "/var/jb/usr/lib/libcolorpicker.dylib",
        "/usr/lib/libcolorpicker.dylib"
    };
    for (NSUInteger i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *handle = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (handle || NSClassFromString(@"PFSimpleLiteColorCell")) break;
    }
}

static id BFDirectSavedColor(NSString *key) {
    NSArray<NSString *> *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.joemama383.badgeforge.plist",
        @"/var/mobile/Library/Preferences/com.joemama383.badgeforge.plist"
    ];
    for (NSString *path in paths) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        id value = [dict isKindOfClass:[NSDictionary class]] ? dict[key] : nil;
        if (value) return value;
    }
    return nil;
}

static id BFCurrentSavedColor(NSString *key) {
    id directValue = BFDirectSavedColor(key);
    if (directValue) return directValue;

    CFPreferencesAppSynchronize((__bridge CFStringRef)BFPreferencesDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)BFPreferencesDomain);
    return CFBridgingRelease(value);
}

@implementation BFRootListController

- (UIColor *)badgeForgeAccentColor {
    return [UIColor colorWithRed:1.0 green:0.23 blue:0.08 alpha:1.0];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = [self badgeForgeAccentColor];
}

- (void)bf_syncColorPickerFallbacksToSavedValues {
    NSMutableArray<PSSpecifier *> *changedSpecifiers = [NSMutableArray array];

    // PFSimpleLiteColorCell on current rootless Preferences can keep displaying
    // the static fallback after its picker writes the real value. The runtime
    // preference plist is authoritative, so update only the in-memory nested
    // libcolorpicker fallback before the cells reload. Nothing is written here.
    for (PSSpecifier *specifier in [self specifiers]) {
        NSDictionary *picker = [specifier propertyForKey:@"libcolorpicker"];
        if (![picker isKindOfClass:[NSDictionary class]]) continue;

        NSString *key = picker[@"key"];
        if (![key isKindOfClass:[NSString class]]) continue;
        if (![key isEqualToString:@"badgeColor"] &&
            ![key isEqualToString:@"textColor"] &&
            ![key isEqualToString:@"borderColor"]) continue;

        id savedValue = BFCurrentSavedColor(key);
        if (![savedValue isKindOfClass:[NSString class]]) continue;
        if ([savedValue isEqual:picker[@"fallback"]]) continue;

        NSMutableDictionary *updatedPicker = [picker mutableCopy];
        updatedPicker[@"fallback"] = savedValue;
        [specifier setProperty:updatedPicker forKey:@"libcolorpicker"];
        [changedSpecifiers addObject:specifier];
    }

    for (PSSpecifier *specifier in changedSpecifiers) {
        [self reloadSpecifier:specifier];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UIColor *accent = [self badgeForgeAccentColor];
    self.view.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;
    [self bf_syncColorPickerFallbacksToSavedValues];
}

- (NSArray *)specifiers {
    BFEnsureColorPickerLoaded();
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)respring {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         BFRespringNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

@end
