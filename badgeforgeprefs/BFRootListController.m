#import "BFRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>

#define BFRespringNotification CFSTR("com.joemama383.badgeforge.respring")

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
