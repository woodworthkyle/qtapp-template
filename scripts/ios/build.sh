#!/usr/bin/env bash
# build.sh — full xcodebuild + device install.
#
# Reads config from config.env at the repo root (or from environment):
#   DEVICE_UUID, BUNDLE_ID, APP_NAME, XCODE_PROJECT, BUILD_CONFIG, SDK
#   DEVELOPMENT_TEAM — Apple team ID (10-char, e.g. "AB12CD34EF")
#
# For headless / CI provisioning (no Xcode GUI required), set App Store
# Connect API key variables — xcodebuild uses these to create/update
# provisioning profiles directly in the Apple Developer portal, which is
# required for entitlements like iCloud that need a non-wildcard profile:
#
#   ASC_KEY_PATH      — absolute path to the .p8 private key file
#   ASC_KEY_ID        — 10-char key ID shown in ASC > Users and Access > Keys
#   ASC_KEY_ISSUER_ID — issuer UUID shown on the same page
#
# One-time setup:
#   1. https://appstoreconnect.apple.com/access/integrations/api
#   2. Create a key with "Developer" role (Admin for first-time profile creation)
#   3. Download the .p8 file (only downloadable once) and note the Key ID + Issuer ID
#   4. Add to config.env:
#        ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
#        ASC_KEY_ID=XXXXXXXXXX
#        ASC_KEY_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

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

# Build output directory, DerivedData, and final .app path
BUILD_DIR="$(dirname "${XCODE_PROJECT}")/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/${BUILD_CONFIG}-iphoneos/${APP_NAME}.app"
BUILD_LOG="${BUILD_DIR}/xcodebuild.log"

mkdir -p "${BUILD_DIR}"

# Only pass -xcconfig if the file actually exists
XCCONFIG_ARGS=()
if [[ -n "${XCCONFIG:-}" && -f "${XCCONFIG}" ]]; then
    XCCONFIG_ARGS=(-xcconfig "${XCCONFIG}")
elif [[ -f "${REPO_ROOT}/config.xcconfig" ]]; then
    XCCONFIG_ARGS=(-xcconfig "${REPO_ROOT}/config.xcconfig")
fi

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

# App Store Connect API key — enables headless provisioning without Xcode GUI.
# When set, xcodebuild can create/update provisioning profiles in the portal,
# which is required for iCloud and other capabilities needing non-wildcard profiles.
ASC_KEY_PATH="${ASC_KEY_PATH:-}"
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_KEY_ISSUER_ID="${ASC_KEY_ISSUER_ID:-}"

ASC_AUTH_ARGS=()
if [[ -n "${ASC_KEY_PATH}" && -n "${ASC_KEY_ID}" && -n "${ASC_KEY_ISSUER_ID}" ]]; then
    if [[ ! -f "${ASC_KEY_PATH}" ]]; then
        echo "ERROR: ASC_KEY_PATH not found: ${ASC_KEY_PATH}" >&2
        exit 1
    fi
    ASC_AUTH_ARGS=(
        -authenticationKeyPath "${ASC_KEY_PATH}"
        -authenticationKeyID "${ASC_KEY_ID}"
        -authenticationKeyIssuerID "${ASC_KEY_ISSUER_ID}"
    )
    echo "    Auth: App Store Connect API key ${ASC_KEY_ID}"
else
    echo "    Auth: local Xcode keychain (no ASC key configured)"
    echo "    Note: iCloud entitlements require a non-wildcard profile."
    echo "          Set ASC_KEY_PATH/ASC_KEY_ID/ASC_KEY_ISSUER_ID in config.env"
    echo "          for fully headless provisioning."
fi

echo "==> Building ${APP_NAME} (${BUILD_CONFIG} / ${SDK})..."
echo "    Project:  ${XCODE_PROJECT}"
echo "    DerivedData: ${DERIVED_DATA}"
echo "    Log:      ${BUILD_LOG}"

# Run xcodebuild, tee full output to log, and show only important lines on
# stdout.  Capture xcodebuild's own exit code before grep can obscure it.
set +e
xcodebuild \
    -allowProvisioningUpdates \
    build \
    "${XCCONFIG_ARGS[@]+"${XCCONFIG_ARGS[@]}"}" \
    "${ASC_AUTH_ARGS[@]+"${ASC_AUTH_ARGS[@]}"}" \
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
    2>&1 | tee "${BUILD_LOG}" \
         | grep --line-buffered -E "(error:|warning:.*error|BUILD SUCCEEDED|BUILD FAILED|Signing|Provisioning)" \
         | grep -v "^note:"
XCODE_STATUS=${PIPESTATUS[0]}
set -e

if [[ $XCODE_STATUS -ne 0 ]]; then
    echo "" >&2

    # Detect iCloud container not registered — the most common first-time failure
    # when the app has iCloud entitlements and the container hasn't been created
    # in the Apple Developer portal yet.  -allowProvisioningUpdates creates the
    # App ID and profile automatically, but iCloud containers must be registered
    # manually (once per bundle ID) because Apple doesn't auto-create them.
    if grep -q "ubiquity-container-identifiers" "${BUILD_LOG}" 2>/dev/null; then
        ICLOUD_CONTAINER="iCloud.${BUNDLE_ID:-dev.yourname.yourapp}"
        echo "──────────────────────────────────────────────────────────────────" >&2
        echo "ACTION REQUIRED: iCloud container not registered" >&2
        echo "" >&2
        echo "The provisioning profile was created but has an empty" >&2
        echo "ubiquity-container-identifiers list. iCloud containers must be" >&2
        echo "registered manually in the Apple Developer portal (once per bundle ID)." >&2
        echo "" >&2
        echo "Step 1 — Register the iCloud container:" >&2
        echo "  https://developer.apple.com/account/resources/identifiers/list/cloudContainer" >&2
        echo "  → + → iCloud Containers → Continue" >&2
        echo "  Description : ${BUNDLE_ID:-yourapp} iCloud" >&2
        echo "  Identifier  : ${ICLOUD_CONTAINER}" >&2
        echo "  → Register" >&2
        echo "" >&2
        echo "Step 2 — Associate the container with the App ID:" >&2
        echo "  https://developer.apple.com/account/resources/identifiers/list/bundleId" >&2
        echo "  → click '${BUNDLE_ID:-dev.yourname.yourapp}' → iCloud → Configure" >&2
        echo "  → add '${ICLOUD_CONTAINER}' → Continue → Save" >&2
        echo "" >&2
        echo "Step 3 — Delete the stale profile and rebuild:" >&2
        echo "  find ~/Library/Developer/Xcode/UserData/Provisioning\\ Profiles \\" >&2
        echo "       -name '*.mobileprovision' -newer '${BUILD_LOG}' -delete" >&2
        echo "  bash scripts/ios/build.sh" >&2
        echo "──────────────────────────────────────────────────────────────────" >&2
    else
        echo "ERROR: xcodebuild failed (exit ${XCODE_STATUS}). Last errors:" >&2
        grep "error:" "${BUILD_LOG}" | tail -30 >&2 || true
    fi

    echo "" >&2
    echo "Full log: ${BUILD_LOG}" >&2
    exit "${XCODE_STATUS}"
fi

if [[ ! -d "${APP_PATH}" ]]; then
    echo "ERROR: Build appeared to succeed but .app not found at:" >&2
    echo "       ${APP_PATH}" >&2
    echo "Full log: ${BUILD_LOG}" >&2
    exit 1
fi

echo "==> Installing to device ${DEVICE_UUID}..."
xcrun devicectl device install app \
    --device "${DEVICE_UUID}" \
    "${APP_PATH}"

echo "==> Build + install complete."
