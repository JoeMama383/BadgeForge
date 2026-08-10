#import "BFRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

#define BFRespringNotification CFSTR("com.joemama383.badgeforge.respring")

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

- (void)respring {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         BFRespringNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

@end
