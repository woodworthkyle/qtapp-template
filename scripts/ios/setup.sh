#!/usr/bin/env bash
# setup.sh — one-time project setup for qtapp iOS (no Briefcase)
#
# What this script does:
#   1. Checks prerequisites (xcodegen, pip, Python 3.12+).
#   2. Downloads Python.xcframework from BeeWare Python-Apple-support.
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
# BeeWare Python-Apple-support uses tag format: "3.12-b8"
# Set PYTHON_SUPPORT_TAG to override, e.g. "3.12-b8" or "3.13-b13"
PYTHON_TAG="${PYTHON_TAG:-3.12}"              # minor version, e.g. "3.12"
PYTHON_BUILD="${PYTHON_BUILD:-b8}"            # build tag, e.g. "b8"
PYTHON_SUPPORT_TAG="${PYTHON_SUPPORT_TAG:-${PYTHON_TAG}-${PYTHON_BUILD}}"

FRAMEWORKS_DIR="${IOS_DIR}/frameworks"
# Bundle resources sit directly inside scripts/ios/ as folder references.
# Layout matches main.m expectations: python/ app/ app_packages/ at bundle root.
APP_SRC_DIR="${REPO_ROOT}/src/qtapp"
APP_DEST_DIR="${IOS_DIR}/app/qtapp"
APP_PACKAGES_DIR="${IOS_DIR}/app_packages"

PYTHON_XCF_NAME="Python-${PYTHON_TAG}-iOS-support.${PYTHON_BUILD}.tar.gz"
PYTHON_XCF_URL="https://github.com/beeware/Python-Apple-support/releases/download/${PYTHON_SUPPORT_TAG}/${PYTHON_XCF_NAME}"
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
mkdir -p "${IOS_DIR}/python"

# ── Download Python.xcframework ───────────────────────────────────────────────
PYTHON_XCF_DIR="${FRAMEWORKS_DIR}/Python.xcframework"
if [[ -d "${PYTHON_XCF_DIR}" ]]; then
    log "Python.xcframework already present — skipping download."
    log "  (delete ${PYTHON_XCF_DIR} to re-download)"
else
    log "Downloading Python.xcframework ${PYTHON_SUPPORT_TAG}..."
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
# Python-Apple-support xcframework layout:
#   Python.xcframework/
#     lib/python${TAG}/          ← stdlib lives here (top-level, shared across slices)
#     ios-arm64/Python.framework/ ← framework binary + headers only
STDLIB_SRC="${PYTHON_XCF_DIR}/lib/python${PYTHON_TAG}"
STDLIB_DEST="${IOS_DIR}/python/lib/python${PYTHON_TAG}"
# Python home expected by main.m: {bundleRoot}/python
# PYTHONPATH: {bundleRoot}/python/lib/python${TAG} and .../lib-dynload

if [[ -d "${STDLIB_DEST}" ]]; then
    log "Python stdlib already present — skipping."
else
    if [[ ! -d "${STDLIB_SRC}" ]]; then
        die "Expected stdlib at ${STDLIB_SRC} — check Python.xcframework layout."
    fi
    log "Copying Python stdlib to resources/python/..."
    mkdir -p "${STDLIB_DEST}"
    rsync -a "${STDLIB_SRC}/" "${STDLIB_DEST}/"
    log "Stdlib ready ($(find "${STDLIB_DEST}" -name "*.py" | wc -l | tr -d ' ') .py files)"
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
