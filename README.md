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

## v1.0.2

- Fix GitHub Actions signing on macOS by installing Theos' required `ldid` and `xz` build dependencies before compiling.
- Verify `ldid` is on `PATH` before the package build starts.

## v1.0.1

- Fix Objective-C++ compilation on Theos by explicitly casting `calloc` results used by the adaptive icon-color sampler.
- Add the standard C allocation header explicitly.
