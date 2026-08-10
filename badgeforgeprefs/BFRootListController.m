#import "BFRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

#define BFRespringNotification CFSTR("com.joemama383.badgeforge.respring")

#define BFPreferencesDomain @"com.joemama383.badgeforge"
#define BFSettingsChangedNotification CFSTR("com.joemama383.badgeforge.settingschanged")

static NSString *BFPreferencePlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.joemama383.badgeforge.plist"];
}

static BOOL BFIsColorPreferenceKey(NSString *key) {
    return [key isEqualToString:@"badgeColor"] ||
           [key isEqualToString:@"textColor"] ||
           [key isEqualToString:@"borderColor"];
}

static void BFMirrorPreferenceToDirectPlist(NSString *key, id value) {
    if (!key || !value) return;
    NSString *path = BFPreferencePlistPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[key] = value;
    [prefs writeToFile:path atomically:YES];
}

static void BFPostSettingsChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         BFSettingsChangedNotification,
                                         NULL, NULL, YES);
}

static void BFEnsureColorPickerLoaded(void) {
    if (NSClassFromString(@"PFSimpleLiteColorCell")) return;

    // libcolorpicker is a runtime package dependency. The original Tinge pane
    // loads this dylib into Preferences; without it a PSLinkCell can navigate
    // to an empty/black controller. Load it explicitly before parsing Root.plist.
    const char *paths[] = {
        "/var/jb/usr/lib/libcolorpicker.dylib",
        "/usr/lib/libcolorpicker.dylib"
    };
    for (NSUInteger i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *handle = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (handle || NSClassFromString(@"PFSimpleLiteColorCell")) break;
    }
}

@implementation BFRootListController

- (UIColor *)badgeForgeAccentColor {
    return [UIColor colorWithRed:1.0 green:0.23 blue:0.08 alpha:1.0];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = [self badgeForgeAccentColor];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UIColor *accent = [self badgeForgeAccentColor];
    self.view.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;
}

- (NSArray *)specifiers {
    BFEnsureColorPickerLoaded();
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: BFPreferencesDomain;
    id fallback = [specifier propertyForKey:@"default"];
    if (!key) return fallback;

    // Only legacy color cells need the direct-plist bridge. Keep ordinary
    // PreferenceLoader controls on CFPreferences so a stale legacy plist can
    // never override switches/segments/text fields.
    if (BFIsColorPreferenceKey(key)) {
        NSDictionary *direct = [NSDictionary dictionaryWithContentsOfFile:BFPreferencePlistPath()];
        id directValue = direct[key];
        if (directValue) return directValue;
    }

    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFPropertyListRef copied = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                         (__bridge CFStringRef)domain);
    return copied ? CFBridgingRelease(copied) : fallback;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: BFPreferencesDomain;
    if (!key || !value) {
        [super setPreferenceValue:value specifier:specifier];
        return;
    }

    // Write both persistence paths. This keeps standard PreferenceLoader
    // controls, libcolorpicker, and SpringBoard in agreement on Dopamine.
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    if (BFIsColorPreferenceKey(key)) BFMirrorPreferenceToDirectPlist(key, value);
    BFPostSettingsChanged();
}

- (void)respring {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         BFRespringNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

@end
