ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:17.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BadgeForge
BadgeForge_FILES = Tweak.xm
BadgeForge_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BadgeForge_FRAMEWORKS = UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += badgeforgeprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
