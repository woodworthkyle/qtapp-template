#!/usr/bin/env bash
# setup.sh — one-time project setup for qtapp iOS (no Briefcase)
#
# What this script does:
#   1. Checks prerequisites (xcodegen, pip, Python 3.12+).
#   2. Downloads Python.xcframework from BeeWare cpython-apple-support.
#   3. Unpacks Python.xcframework into scripts/ios/frameworks/.
#   4. Installs pip dependencies into scripts/ios/resources/app_packages/.
#   5. Copies app source into scripts/ios/resources/app/.
#   6. Runs `xcodegen generate` to produce the .xcodeproj.
#
# Run from the repo root:
#   source config.env && bash scripts/ios/setup.sh
#
# Or set variables inline:
#   APP_NAME=MyApp BUNDLE_ID=dev.you.myapp bash scripts/ios/setup.sh
#
# After running, open ${APP_NAME}.xcodeproj in Xcode and:
#   - Set your signing team (or drop in an .xcconfig).
#   - Build and run on device (or use scripts/ios/build.sh).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_DIR="${REPO_ROOT}/scripts/ios"

# ── Load config.env if present ────────────────────────────────────────────────
CONFIG_ENV="${REPO_ROOT}/config.env"
if [[ -f "${CONFIG_ENV}" ]]; then
    # shellcheck disable=SC1090
    set -a; source "${CONFIG_ENV}"; set +a
fi

# ── Variables (with defaults) ─────────────────────────────────────────────────
APP_NAME="${APP_NAME:-QtApp}"
BUNDLE_ID="${BUNDLE_ID:-dev.kwoodworth.qtapp}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12.10}"   # cpython-apple-support release tag
PYTHON_TAG="${PYTHON_TAG:-3.12}"              # e.g. "3.12" for path construction

FRAMEWORKS_DIR="${IOS_DIR}/frameworks"
RESOURCES_DIR="${IOS_DIR}/resources"
APP_SRC_DIR="${REPO_ROOT}/src/qtapp"
APP_DEST_DIR="${RESOURCES_DIR}/app/qtapp"
APP_PACKAGES_DIR="${RESOURCES_DIR}/app_packages"

PYTHON_XCF_NAME="Python-${PYTHON_VERSION}-iOS-support.b2.tar.gz"
PYTHON_XCF_URL="https://github.com/beeware/cpython-apple-support/releases/download/${PYTHON_VERSION}/${PYTHON_XCF_NAME}"
PYTHON_XCF_ARCHIVE="${IOS_DIR}/${PYTHON_XCF_NAME}"

log()  { echo "[setup] $*"; }
die()  { echo "[setup] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1  (install with: $2)"; }

# ── Prerequisite checks ───────────────────────────────────────────────────────
log "Checking prerequisites..."
need xcodegen  "brew install xcodegen"
need python3   "install from python.org or brew install python"
need pip3      "comes with Python — try: python3 -m ensurepip"
need curl      "install Xcode command-line tools: xcode-select --install"
need tar       "install Xcode command-line tools: xcode-select --install"

PYTHON_VER_ACTUAL="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
log "Host Python: ${PYTHON_VER_ACTUAL}"

# ── Create directory structure ────────────────────────────────────────────────
log "Creating directory structure..."
mkdir -p "${FRAMEWORKS_DIR}"
mkdir -p "${APP_DEST_DIR}"
mkdir -p "${APP_PACKAGES_DIR}"

# ── Download Python.xcframework ───────────────────────────────────────────────
PYTHON_XCF_DIR="${FRAMEWORKS_DIR}/Python.xcframework"
if [[ -d "${PYTHON_XCF_DIR}" ]]; then
    log "Python.xcframework already present — skipping download."
    log "  (delete ${PYTHON_XCF_DIR} to re-download)"
else
    log "Downloading Python.xcframework ${PYTHON_VERSION}..."
    log "  URL: ${PYTHON_XCF_URL}"
    curl -L --progress-bar -o "${PYTHON_XCF_ARCHIVE}" "${PYTHON_XCF_URL}"

    log "Extracting Python.xcframework..."
    tar -xzf "${PYTHON_XCF_ARCHIVE}" -C "${FRAMEWORKS_DIR}"
    rm -f "${PYTHON_XCF_ARCHIVE}"

    # The archive typically extracts to Python-<ver>-iOS-support.b2/
    # which contains Python.xcframework.  Move it up if needed.
    EXTRACTED_XCF="$(find "${FRAMEWORKS_DIR}" -maxdepth 2 -name "Python.xcframework" -type d | head -1)"
    if [[ -z "${EXTRACTED_XCF}" ]]; then
        die "Python.xcframework not found after extraction in ${FRAMEWORKS_DIR}"
    fi
    if [[ "${EXTRACTED_XCF}" != "${PYTHON_XCF_DIR}" ]]; then
        mv "${EXTRACTED_XCF}" "${PYTHON_XCF_DIR}"
        # Clean up extracted support dir if empty
        PARENT_DIR="$(dirname "${EXTRACTED_XCF}")"
        [[ "${PARENT_DIR}" != "${FRAMEWORKS_DIR}" ]] && rmdir "${PARENT_DIR}" 2>/dev/null || true
    fi
    log "Python.xcframework ready at: ${PYTHON_XCF_DIR}"
fi

# ── Install Python stdlib into resources/python ───────────────────────────────
# Python.xcframework bundles the stdlib as a zip; unpack it so the interpreter
# can find modules without zipimport (simpler path setup, easier to inspect).
STDLIB_SRC="${PYTHON_XCF_DIR}/ios-arm64/Python.framework/lib/python${PYTHON_TAG}"
STDLIB_DEST="${RESOURCES_DIR}/python/lib/python${PYTHON_TAG}"

if [[ -d "${STDLIB_DEST}" ]]; then
    log "Python stdlib already unpacked — skipping."
else
    log "Unpacking Python stdlib to resources/python/..."
    mkdir -p "${STDLIB_DEST}"
    # Copy stdlib (Python.xcframework ships it unpacked in the framework)
    if [[ -d "${STDLIB_SRC}" ]]; then
        rsync -a "${STDLIB_SRC}/" "${STDLIB_DEST}/"
        log "Stdlib copied from xcframework."
    else
        die "Expected stdlib at ${STDLIB_SRC} — check Python.xcframework layout."
    fi

    # Also copy lib-dynload (binary extension modules)
    LIB_DYNLOAD_SRC="${STDLIB_SRC}/lib-dynload"
    if [[ -d "${LIB_DYNLOAD_SRC}" ]]; then
        log "Copying lib-dynload..."
        mkdir -p "${STDLIB_DEST}/lib-dynload"
        cp -R "${LIB_DYNLOAD_SRC}/" "${STDLIB_DEST}/lib-dynload/"
    fi
fi

# ── Copy app source ───────────────────────────────────────────────────────────
log "Syncing app source -> ${APP_DEST_DIR}..."
rsync -a --delete "${APP_SRC_DIR}/" "${APP_DEST_DIR}/"

# ── Install pip dependencies into app_packages ────────────────────────────────
REQUIREMENTS="${REPO_ROOT}/requirements-ios.txt"
if [[ -f "${REQUIREMENTS}" ]]; then
    log "Installing pip dependencies from requirements-ios.txt..."
    pip3 install \
        --target "${APP_PACKAGES_DIR}" \
        --no-deps \
        --platform iphoneos \
        --python-version "${PYTHON_TAG}" \
        --only-binary :all: \
        -r "${REQUIREMENTS}" \
        || die "pip install failed — check requirements-ios.txt"
else
    log "No requirements-ios.txt found — skipping pip install."
    log "  Create ${REQUIREMENTS} with iOS-compatible wheel names if needed."
fi

# ── Generate Xcode project ────────────────────────────────────────────────────
XCODEGEN_SPEC="${IOS_DIR}/xcodegen.yml"
log "Running xcodegen generate..."
cd "${IOS_DIR}"
APP_NAME="${APP_NAME}" BUNDLE_ID="${BUNDLE_ID}" \
    xcodegen generate --spec "${XCODEGEN_SPEC}"

XCODEPROJ="${IOS_DIR}/${APP_NAME}.xcodeproj"
if [[ -d "${XCODEPROJ}" ]]; then
    log ""
    log "──────────────────────────────────────────────────────────────────────"
    log "  Setup complete!"
    log ""
    log "  Xcode project: ${XCODEPROJ}"
    log ""
    log "  Next steps:"
    log "    1. open '${XCODEPROJ}'"
    log "    2. Set your signing team in the project settings"
    log "       (or add CODE_SIGN_TEAM to config.env and re-run setup.sh)"
    log "    3. Build and run on a connected device"
    log "       Or use: bash scripts/ios/build.sh"
    log "──────────────────────────────────────────────────────────────────────"
else
    die "xcodegen did not produce ${XCODEPROJ}"
fi
