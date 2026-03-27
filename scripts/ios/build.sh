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
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
SDK="${SDK:-iphoneos}"
APP_NAME="${APP_NAME:-QtApp}"

# XCODE_PROJECT may be relative to repo root or absolute
XCODE_PROJECT="${XCODE_PROJECT:-scripts/ios/${APP_NAME}.xcodeproj}"
if [[ "${XCODE_PROJECT}" != /* ]]; then
    XCODE_PROJECT="${REPO_ROOT}/${XCODE_PROJECT}"
fi

# Build output directory and final .app path (absolute)
BUILD_DIR="$(dirname "${XCODE_PROJECT}")/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/${BUILD_CONFIG}-iphoneos/${APP_NAME}.app"

# Only pass -xcconfig if the file actually exists
XCCONFIG_ARGS=()
if [[ -n "${XCCONFIG:-}" && -f "${XCCONFIG}" ]]; then
    XCCONFIG_ARGS=(-xcconfig "${XCCONFIG}")
elif [[ -f "${REPO_ROOT}/config.xcconfig" ]]; then
    XCCONFIG_ARGS=(-xcconfig "${REPO_ROOT}/config.xcconfig")
fi

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

echo "==> Building ${APP_NAME} (${BUILD_CONFIG} / ${SDK})..."
echo "    Project: ${XCODE_PROJECT}"
xcodebuild \
    -allowProvisioningUpdates \
    build \
    "${XCCONFIG_ARGS[@]+"${XCCONFIG_ARGS[@]}"}" \
    -project "${XCODE_PROJECT}" \
    -scheme "${APP_NAME}" \
    -configuration "${BUILD_CONFIG}" \
    -arch arm64 \
    -sdk "${SDK}" \
    -derivedDataPath "${DERIVED_DATA}" \
    TARGETED_DEVICE_FAMILY=1 \
    ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}"} \
    CODE_SIGN_STYLE=Automatic \
    PROVISIONING_PROFILE_SPECIFIER="" \
    | grep -E "(error:|warning: .*(error|failed)|BUILD |FAILED)" \
    | grep -v "^note:" || true

if [[ ! -d "${APP_PATH}" ]]; then
    echo "ERROR: Build failed — ${APP_PATH} not found" >&2
    exit 1
fi

echo "==> Installing to device ${DEVICE_UUID}..."
xcrun devicectl device install app \
    --device "${DEVICE_UUID}" \
    "${APP_PATH}"

echo "==> Build + install complete."
