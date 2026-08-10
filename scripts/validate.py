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

prefs_text = (root / "badgeforgeprefs/Resources/Root.plist").read_text()
for key in ["tweakEnabled", "badgeColorType", "badgeColor", "textColorType", "textColor",
            "borderEnabled", "borderWidth", "borderColorType", "borderColor", "Respring!"]:
    if key not in prefs_text:
        errors.append(f"Root.plist missing {key}")

if errors:
    print("\nFAILED")
    for err in errors:
        print(" -", err)
    sys.exit(1)
print("\nBadgeForge source validation: PASS")
