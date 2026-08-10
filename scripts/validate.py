#!/usr/bin/env python3
from pathlib import Path
import plistlib
import re
import sys

root = Path(__file__).resolve().parents[1]
errors = []

plists = [
    root / "BadgeForge.plist",
    root / "badgeforgeprefs/Resources/Info.plist",
    root / "badgeforgeprefs/Resources/Root.plist",
    root / "layout/Library/PreferenceLoader/Preferences/BadgeForge.plist",
]
for path in plists:
    try:
        with path.open("rb") as f:
            plistlib.load(f)
        print(f"OK plist: {path.relative_to(root)}")
    except Exception as exc:
        errors.append(f"{path}: {exc}")

control = (root / "control").read_text()
required = ["Package:", "Name:", "Version:", "Architecture: iphoneos-arm64", "Depends:"]
for token in required:
    if token not in control:
        errors.append(f"control missing {token}")

source = (root / "Tweak.xm").read_text()
for hook in [
    "configureForIcon:(id)icon infoProvider:(id)provider",
    "configureAnimatedForIcon:(id)icon infoProvider:(id)provider animator:(id)animator",
    "_crossfadeToTextImage:(UIImage *)image animator:(id)animator",
    "layoutSubviews",
    "drawRect:(CGRect)rect",
]:
    if hook not in source:
        errors.append(f"Tweak.xm missing hook: {hook}")

if source.count("%hook") != source.count("%end"):
    errors.append("Logos hook/end count mismatch")

# Tweak.xm is preprocessed by Logos as Objective-C++, where void* does not
# implicitly convert to typed pointers. Keep heap allocation sites explicit.
raw_calloc_assignments = re.findall(r"(?:uint8_t|double)\s*\*\s*\w+\s*=\s*calloc\s*\(", source)
if raw_calloc_assignments:
    errors.append("Tweak.xm contains uncast calloc assignment(s) that fail under Objective-C++")

prefs_text = (root / "badgeforgeprefs/Resources/Root.plist").read_text()
for key in ["tweakEnabled", "badgeColorType", "badgeColor", "textColorType", "textColor",
            "borderEnabled", "borderWidth", "borderColorType", "borderColor", "Respring!"]:
    if key not in prefs_text:
        errors.append(f"Root.plist missing {key}")

# CI must provide ldid before Theos reaches its signing stage on macOS.
workflow = (root / ".github/workflows/build.yml").read_text()
if not re.search(r"brew\s+install[^\n]*\bldid\b", workflow):
    errors.append("GitHub Actions workflow does not install ldid")
if "command -v ldid" not in workflow:
    errors.append("GitHub Actions workflow does not verify ldid is on PATH")

if '"$THEOS/bin/install-sdk" latest' not in workflow:
    errors.append("GitHub Actions workflow does not install a patched Theos SDK")
if "PrivateFrameworks/Preferences.framework" not in workflow:
    errors.append("GitHub Actions workflow does not verify the Preferences private framework SDK stub")
makefile = (root / "Makefile").read_text()
if "export TARGET = iphone:clang:16.5:15.0" not in makefile:
    errors.append("root Makefile does not export the patched SDK target to subprojects")


# Adaptive badge color must bind the real owning SBIcon and use a correctly
# sized SBIconImageInfo before falling back to the bundle-id image path.
for token in [
    "_applicationIconImageForBundleIdentifier:format:scale:",
    "BFBundleIdentifierForIcon",
    "BFAverageColorFromImage",
    "BFAdaptiveColorForIcon",
]:
    if token not in source:
        errors.append(f"Tweak.xm missing adaptive-color component: {token}")
if "? 8 : 10" not in source:
    errors.append("Tweak.xm missing modern iPad/iPhone icon format selection (8/10)")


for token in [
    "CGFloat continuousCornerRadius;",
    "info.continuousCornerRadius = 12.0;",
    "BFResolveIconForBadge",
    "%hook SBIconView",
    "BFBindBadgeDescendants",
]:
    if token not in source:
        errors.append(f"Tweak.xm missing iOS 17 icon-binding component: {token}")

prefs_controller = (root / "badgeforgeprefs/BFRootListController.m").read_text()
for token in [
    "BFEnsureColorPickerLoaded",
    "/var/jb/usr/lib/libcolorpicker.dylib",
    "RTLD_NOW | RTLD_GLOBAL",
]:
    if token not in prefs_controller:
        errors.append(f"preference controller missing color-picker loader component: {token}")

# Keep user-visible/package versions synchronized.
if "Version: 1.0.13" not in control:
    errors.append("control version is not 1.0.13")
info = (root / "badgeforgeprefs/Resources/Info.plist").read_text()
if "<string>1.0.13</string>" not in info:
    errors.append("preference bundle version is not 1.0.13")
if "BadgeForge 1.0.13 • iOS 17 rootless" not in prefs_text:
    errors.append("preference footer version is not 1.0.13")
if "BadgeForge 1.0.13 probe start" not in source:
    errors.append("runtime probe banner is not 1.0.13")

for token in [
    "LCPParseColorString",
    "/var/mobile/BadgeForgeProbe.log",
    "BFProbeDumpBadge",
    "BFProbeDiscoverBadgeClasses",
    "after-80ms",
]:
    if token not in source:
        errors.append(f"Tweak.xm missing v1.0.6 probe/static-color component: {token}")

if "BFStringValue" in source:
    errors.append("Tweak.xm still contains the unused BFStringValue helper that breaks -Werror builds")
for token in [
    "BFProbeJailbreakEnvironment",
    "_dyld_image_count",
    "libellekit.dylib",
    "loaded jailbreak/hook images=",
]:
    if token not in source:
        errors.append(f"Tweak.xm missing v1.0.8 Dopamine/runtime probe component: {token}")


for token in [
    "BFColorPreferenceValue",
    "/var/jb/var/mobile/Library/Preferences/com.joemama383.badgeforge.plist",
    "source=direct-plist",
]:
    if token not in source:
        errors.append(f"Tweak.xm missing v1.0.8 direct color preference bridge: {token}")

for forbidden in [
    "readPreferenceValue:(PSSpecifier *)specifier",
    "setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier",
    "BFMirrorPreferenceToDirectPlist",
]:
    if forbidden in prefs_controller:
        errors.append(f"preference controller still overrides libcolorpicker persistence: {forbidden}")

root_plist = plistlib.loads((root / "badgeforgeprefs/Resources/Root.plist").read_bytes())
color_rows = [item for item in root_plist.get("items", []) if item.get("cellClass") == "PFSimpleLiteColorCell"]
if len(color_rows) != 3:
    errors.append(f"expected 3 libcolorpicker rows, found {len(color_rows)}")
for row in color_rows:
    if any(k in row for k in ("defaults", "key", "default", "PostNotification")):
        errors.append(f"color row {row.get('label')} has top-level persistence keys; libcolorpicker must own persistence")
    nested = row.get("libcolorpicker", {})
    for key in ("defaults", "key", "fallback", "PostNotification"):
        if key not in nested:
            errors.append(f"color row {row.get('label')} missing nested libcolorpicker {key}")

# v1.0.13: use the stock badge renderer lifecycle instead of replacing the
# background with a custom 2x2 bitmap. This is required for Home Screen badge
# reuse/app-close refresh, while preserving the original border-layer path.
for token in [
    "BFPaletteKey",
    "BFPaletteForBadge",
    "BFStorePaletteForBadgeAndIcon",
    "BFColoredTextRaster",
    "BFUpdateBadgeColors",
    "imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate",
    "imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal",
    "- (void)updateBadgeColors",
    "%hook SBDarkeningImageView",
    "%hook UIImageView",
    "layer.borderWidth = BFBorderEnabled ? BFBorderWidth : 0.0",
    "layer.masksToBounds = YES",
    "BFApplyBadgeWithTextImageHint",
    "BFScheduleFinalBadgeReapply",
    "_configureAnimatedForText:(NSString *)text highlighted:(BOOL)highlighted animator:(id)animator",
    "_resizeForTextImage:(UIImage *)image",
    "_layOutTextImageView:(UIImageView *)imageView",
    "_zoomInWithTextImage:(UIImage *)image animator:(id)animator",
]:
    if token not in source:
        errors.append(f"Tweak.xm missing v1.0.13 stock-renderer lifecycle component: {token}")

for forbidden in [
    "BFFillLayerKey",
    "BadgeForgeFill",
    "BFSyncFillGeometry",
    "BFSolidBadgeImage",
    "BFSolidBadgeImageCache",
    "resizableImageWithCapInsets:UIEdgeInsetsZero",
    "BFRestoreBadge(self);",
    "0.05 * NSEC_PER_SEC",
]:
    if forbidden in source:
        errors.append(f"Tweak.xm still contains retired/racy badge renderer component: {forbidden}")


# The libcolorpicker rows remain nested-only on disk; the preference controller
# may only update the runtime fallback displayed by the cell from the already
# persisted selected color.
for token in [
    "BFDirectSavedColor",
    "BFCurrentSavedColor",
    "bf_syncColorPickerFallbacksToSavedValues",
    'updatedPicker[@"fallback"] = savedValue',
    "reloadSpecifier:specifier",
    "/var/jb/var/mobile/Library/Preferences/com.joemama383.badgeforge.plist",
]:
    if token not in prefs_controller:
        errors.append(f"preference controller missing v1.0.11 saved-color display sync: {token}")
if "reloadSpecifiers" in prefs_controller:
    errors.append("preference controller still reloads the entire list and can disrupt Border Width editing")

# v1.0.12: these helpers became dead code in v1.0.11. The CI toolchain treats
# -Wunused-function as an error, so do not reintroduce them unless they are used.
for forbidden in ["BFSendSize0", "BFSendSize1"]:
    if forbidden in source:
        errors.append(f"Tweak.xm reintroduces unused helper that breaks -Werror build: {forbidden}")

if errors:
    print("\nFAILED")
    for err in errors:
        print(" -", err)
    sys.exit(1)
print("\nBadgeForge source validation: PASS")
