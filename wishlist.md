# qtapp-template wishlist

## iOS: QML plugin loading
- **Custom QML C++ plugins on iOS**: iOS prohibits `dlopen()`, so Qt's plugin
  system (which loads `.so` files at runtime via `plugin` directives in qmldirs)
  cannot work.  The current workaround strips plugin directives and calls
  `qml_register_types_*` symbols directly via ctypes.  A proper solution would
  require either `Q_IMPORT_PLUGIN` in the ObjC entry point (static linking) or
  a PySide6 iOS build that omits plugin directives from its qrc qmldirs.
  Users who need to ship custom QML C++ extension plugins on iOS will hit the
  same wall — investigate a general plugin-loading mechanism for this case.
- **QML stubs version matching**: The Xcode build phase (`prepare_qml_stubs.py`)
  extracts QML files from whatever macOS PySide6 is available, which may not
  match the iOS wheel version.  Upstream fix: add a `qml/` directory to the
  PySide6 iOS wheel itself, eliminating the need for the extraction step.

## iOS bootstrap
- ~~Replace the current Briefcase/Toga iOS bootstrap with a custom Xcode project~~ ✓ Done
- Make app lifecycle handled all in python
  - `AppDelegate.m` (ObjC) is required to call `UIApplicationMain` and bootstrap Python — iOS hard constraint.
  - Option: subclass `QIOSApplicationDelegate` so Qt owns the app delegate, then route all lifecycle events to Python via `QGuiApplication.applicationStateChanged` and `QDesktopServices.setUrlHandler()`.
- `keyWindow` is deprecated on iOS 13+ (use `UIWindowScene.keyWindow`).
  Update any remaining `keyWindow` usage in `platform/ios.py` if it resurfaces.

## iOS: iCloud
- Expose iCloud container in the Files app (requires enabling iCloud Drive in
  Xcode entitlements + enabling "iCloud Documents" capability).
- Pass the correct app-specific container ID to `get_icloud_documents_path()`.

## iOS: URL scheme
- Add `CFBundleURLTypes` to Info.plist for the chosen URL scheme
  (requires `--full` rebuild after adding).

## Setup / project generation
- Write `scripts/setup.py` (or a CLI tool) that bootstraps a new project from
  this template: substitutes bundle ID, app name, signing team into
  config.env + Xcode project; optionally runs `briefcase create ios` to
  generate the initial Xcode scaffold.
- Evaluate replacing Briefcase entirely with a minimal custom Xcode template
  stored in `scripts/ios/xcode-template/` that embeds Python.xcframework directly.

## App icon / branding
- **iOS app icon**: Add an `AppIcon.xcassets` asset catalog with the required
  sizes (20–1024pt).  Reference it in `xcodegen.yml` via `sources` and
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in build settings.
  `setup.sh` or a helper script should accept a source image and generate
  the full set (e.g. with `sips` or ImageMagick).
- **iOS launch screen**: Replace the bare `UILaunchScreen: {}` in Info.plist
  with a proper launch screen.  Options:
  - `UILaunchScreen` dict keys (`UIColorName`, `UIImageName`) for a simple
    background + centered logo — no storyboard required, iOS 14+.
  - `LaunchScreen.storyboard` for full layout control; add to `objc/` and
    reference via `UILaunchStoryboardName` in Info.plist.
- **Display name**: `CFBundleDisplayName` in Info.plist (separate from
  `CFBundleName`) so the home screen label can differ from the binary name.
  Wire through `config.env` alongside `APP_NAME`.

## All platforms
- Remote debugging over WireGuard VPN (Xcode device discovery fails through VPN;
  investigate `xcrun devicectl` as a workaround — it uses Bonjour-independent
  device tunnels and already works).
- Continuous log file: write stderr to a timestamped rolling log in Documents/logs/
  alongside the existing .err exception files.

## Android
- Wire up `platform/android.py` stub with equivalent utilities
  (storage paths, URL scheme, bring-to-front).

## Sub-apps / ideas
- uBlog
- todo/task editor → calendar publish
- Code editor (see `qtiostest/sample_apps/code_editor.py` for reference)

## Build Env
- create mamba env so that proper package versions are used for building