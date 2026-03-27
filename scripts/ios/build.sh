#!/usr/bin/env bash
# build.sh — full xcodebuild + device install.
#
# Reads DEVICE_UUID, BUNDLE_ID, XCODE_PROJECT, BUILD_CONFIG, SDK from
# config.env at the repo root (or from environment).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_ENV="$REPO_ROOT/config.env"

if [[ -f "$CONFIG_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_ENV"
fi

DEVICE_UUID="${DEVICE_UUID:?Set DEVICE_UUID in config.env or environment}"
XCODE_PROJECT="${XCODE_PROJECT:?Set XCODE_PROJECT (path to .xcodeproj dir) in config.env}"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
SDK="${SDK:-iphoneos}"
XCCONFIG="${XCCONFIG:-$REPO_ROOT/config.xcconfig}"

APP_NAME="${APP_NAME:-QtApp}"
BUILD_DIR="$(dirname "$XCODE_PROJECT")/build"
APP_PATH="$BUILD_DIR/${BUILD_CONFIG}-iphoneos/${APP_NAME}.app"

echo "==> Building ${APP_NAME} (${BUILD_CONFIG} / ${SDK})..."
xcodebuild \
    -allowProvisioningUpdates \
    build \
    ${XCCONFIG:+-xcconfig "$XCCONFIG"} \
    -project "$XCODE_PROJECT" \
    -destination "platform=iOS" \
    -configuration "$BUILD_CONFIG" \
    -arch arm64 \
    -sdk "$SDK" \
    TARGETED_DEVICE_FAMILY=1 \
    | grep -E "(error:|BUILD |FAILED)" | grep -v "^note:" || true

echo "==> Installing to device ${DEVICE_UUID}..."
xcrun devicectl device install app \
    --device "$DEVICE_UUID" \
    "$APP_PATH"

echo "==> Build + install complete."
