#!/bin/sh
# sign_pyside6.sh — Xcode "Sign and embed PySide6 dylibs" build phase script.
#
# Signs all PySide6 / shiboken6 dylibs with the project's code signing identity
# and copies them into the app bundle's Frameworks/ directory so that the app
# passes Xcode's code signing validation on device.
#
# Runs as an Xcode run-script build phase (see xcodegen.yml).
# Environment variables (CODESIGNING_FOLDER_PATH, EXPANDED_CODE_SIGN_IDENTITY,
# EFFECTIVE_PLATFORM_NAME) are provided automatically by Xcode.

set -e

# Simulator builds don't need re-signing
if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
    echo "sign_pyside6.sh: simulator build — skipping dylib signing"
    exit 0
fi

APP="${CODESIGNING_FOLDER_PATH}"
FRAMEWORKS="${APP}/Frameworks"
APP_PACKAGES="${APP}/app_packages"

if [ -z "${EXPANDED_CODE_SIGN_IDENTITY}" ]; then
    echo "sign_pyside6.sh: WARNING — EXPANDED_CODE_SIGN_IDENTITY is empty, skipping"
    exit 0
fi

mkdir -p "${FRAMEWORKS}"

sign_count=0
warn_count=0

sign_dylib() {
    local src="$1"
    local name
    name="$(basename "${src}")"
    local dest="${FRAMEWORKS}/${name}"
    cp -f "${src}" "${dest}"
    codesign -f -s "${EXPANDED_CODE_SIGN_IDENTITY}" "${dest}"
    echo "  signed: ${name}"
    sign_count=$((sign_count + 1))
}

echo "sign_pyside6.sh: scanning ${APP_PACKAGES} for dylibs..."

# Sign shiboken6 dylibs
if [ -d "${APP_PACKAGES}/shiboken6" ]; then
    find "${APP_PACKAGES}/shiboken6" -maxdepth 1 -name "*.dylib" | while read -r dylib; do
        sign_dylib "${dylib}"
    done
fi

# Sign PySide6 dylibs (libpyside6*.dylib at top level of PySide6/)
if [ -d "${APP_PACKAGES}/PySide6" ]; then
    find "${APP_PACKAGES}/PySide6" -maxdepth 1 -name "*.dylib" | while read -r dylib; do
        sign_dylib "${dylib}"
    done
fi

# Sign any Qt .framework bundles that PySide6 ships inside app_packages
# (some PySide6 wheels ship Qt as frameworks rather than loose dylibs)
if [ -d "${APP_PACKAGES}/PySide6/Qt/lib" ]; then
    find "${APP_PACKAGES}/PySide6/Qt/lib" -maxdepth 1 -name "*.framework" -type d | while read -r fw; do
        fw_name="$(basename "${fw}")"
        fw_dest="${FRAMEWORKS}/${fw_name}"
        cp -Rf "${fw}" "${fw_dest}"
        codesign -f -s "${EXPANDED_CODE_SIGN_IDENTITY}" "${fw_dest}"
        echo "  signed framework: ${fw_name}"
        sign_count=$((sign_count + 1))
    done
fi

echo "sign_pyside6.sh: done (${sign_count} items signed)"
