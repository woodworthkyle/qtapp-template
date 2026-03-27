# qtapp-template wishlist

## iOS bootstrap (high priority)
- Replace the current Briefcase/Toga iOS bootstrap with a custom Xcode project template
  that calls Python directly from ObjC, removing the Toga dependency entirely at the
  build/infra level (not just the Python level).  `_Bootstrap.main_loop()` currently
  relies on a Briefcase-compatible entry point; a custom bootstrap could call
  `QApplication.exec()` directly from ObjC after Python init.
- Investigate `UIApplicationMain` + `QApplication` coexistence:
  Qt's iOS platform plugin (`libqios`) registers as a `UIApplicationDelegate` subscriber.
  Confirm the correct integration point and whether `QApplication.exec()` is needed
  at all when embedded inside an existing `UIApplicationMain` run loop.
- `keyWindow` is deprecated on iOS 13+ (use `UIWindowScene.keyWindow`).
  Update `raise_qt_view` in `platform/ios.py` accordingly.

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

## All platforms
- App icon + display name configuration per platform.
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
