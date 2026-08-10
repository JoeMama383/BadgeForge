# BadgeForge

BadgeForge is a new rootless iOS 17 SpringBoard tweak for customizing app notification badges.

## Features

- Adaptive badge background derived from the app icon, or a static chosen color
- Adaptive high-contrast text, or a static chosen color
- Optional border with adjustable width
- Border color modes: Adaptive, Match Text Color, or Static
- Live preference refresh through Darwin notifications
- Respring button in Settings
- Folder badges use the badged child app with the highest notification count as the adaptive color source
- App Library / SpringBoard badge views are handled through `SBIconBadgeView`

## Build

The project is configured for Theos rootless packaging and iOS 17. On macOS with Theos installed:

```sh
make clean package FINALPACKAGE=1
```

The resulting `.deb` is placed in `packages/`.

A GitHub Actions workflow is included at `.github/workflows/build.yml` so the source can be pushed from a phone and compiled on a macOS runner.

## Dependencies

Runtime package dependencies are declared in `control`. LibColorPicker is used by the Settings color cells. BadgeForge conflicts with the original `com.p2kdev.tinge` package so two badge painters do not compete for the same SpringBoard view.

## Implementation note

The tweak uses only a declaration for `SBIconBadgeView` and dynamically resolves the other SpringBoard selectors it needs. It does not bundle or redistribute the original Tinge binary or preference resources.

## v1.0.9

- Restore the three libcolorpicker specifiers to the same nested-only persistence contract used by Tinge, removing the v1.0.8 PreferenceLoader bridge that caused selected swatches to reload as their defaults.
- Add a dedicated `BadgeForgeFill` CALayer above iOS 17's stock `SBDarkeningImageView` image contents and below the badge text image. This makes both Static and Adaptive badge background colors visible instead of leaving Apple's red raster on top.
- Preserve the already-working static/adaptive text colors, border width, Match Text Color, and adaptive border behavior.
- Keep the runtime probe for one more build and log the new fill-layer color/frame so the visible painter can be verified independently of the underlying stock image.

## v1.0.8

- Bridge libcolorpicker's legacy direct-plist persistence to SpringBoard on Dopamine/ElleKit so static badge, text, and border colors are actually read after selection.
- Add top-level `defaults`, `key`, and `default` metadata to all three color-picker specifiers while preserving the existing libcolorpicker UI.
- Preference writes now mirror to both CFPreferences and `/var/mobile/Library/Preferences/com.joemama383.badgeforge.plist`, then post the existing Darwin refresh notification.
- Keep the v1.0.7 runtime probe enabled so the next on-device log identifies whether each color came from the direct plist, CFPreferences, or a fallback.

## v1.0.7

- Fix the v1.0.6 CI failure by removing an unused static preference helper that Clang promoted to an error under `-Werror`.
- Keep the iOS 17 badge probe intact and add runtime jailbreak/injection diagnostics for Dopamine/ElleKit-style environments, including rootless path presence and loaded hook-library image names.
- No badge painting behavior was intentionally changed in this diagnostic build.

## v1.0.5

- Install Theos' patched iOS SDK in GitHub Actions so private frameworks such as Preferences are linkable.
- Export an explicit iPhoneOS 16.5 SDK / iOS 15 deployment target to the preference-bundle subproject. The package itself remains restricted to iOS 17+ by its firmware dependency.
- Run source validation before compilation in CI.

## v1.0.2

- Fix GitHub Actions signing on macOS by installing Theos' required `ldid` and `xz` build dependencies before compiling.
- Verify `ldid` is on `PATH` before the package build starts.

## v1.0.1

- Fix Objective-C++ compilation on Theos by explicitly casting `calloc` results used by the adaptive icon-color sampler.
- Add the standard C allocation header explicitly.
