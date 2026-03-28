#!/usr/bin/env bash
# deploy.sh — fast hot-reload deploy to an iOS device (no Xcode rebuild needed).
#
# Copies _app_override.py (+ optional app scripts) to the device in ~2s.
# Only run a full build (--full) when the Xcode project itself changes.
#
# Configuration (set in config.env or export before calling):
#   DEVICE_UUID   — from: xcrun devicectl list devices
#   BUNDLE_ID     — e.g. dev.kwoodworth.myapp
#
# Usage:
#   ./deploy.sh [--full] [--launch] [--app <name>] [--file <path>]
#   ./deploy.sh --deploy-apps          # push all apps/*.py to Documents/

set -euo pipefail

# ── config ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_ENV="$REPO_ROOT/config.env"

if [[ -f "$CONFIG_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_ENV"
fi

DEVICE_UUID="${DEVICE_UUID:?Set DEVICE_UUID in config.env or environment}"
BUNDLE_ID="${BUNDLE_ID:?Set BUNDLE_ID in config.env or environment}"
APP_SRC="$REPO_ROOT/src/qtapp/app.py"
OVERRIDE_DST="Documents/_app_override.py"
APPS_DIR="$REPO_ROOT/apps"
XCODE_PROJECT="${XCODE_PROJECT:-$REPO_ROOT/build/ios/xcode}"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
SDK="${SDK:-iphoneos}"

# ── parse args ─────────────────────────────────────────────────────────────────
FULL=0
LAUNCH=0
DEPLOY_APPS=0
APP_ARG=""
FILE_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --full)        FULL=1 ;;
        --launch)      LAUNCH=1 ;;
        --deploy-apps) DEPLOY_APPS=1 ;;
        --app)         APP_ARG="$2"; shift ;;
        --file)        FILE_ARG="$2"; shift ;;
        *) ;;
    esac
    shift
done

_devicectl_copy() {
    local src="$1" dst="$2"
    xcrun devicectl device copy to \
        --device "$DEVICE_UUID" \
        --source "$src" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --destination "$dst"
}

# ── full build ─────────────────────────────────────────────────────────────────
if [[ $FULL -eq 1 ]]; then
    echo "==> Full build + install..."
    "$SCRIPT_DIR/build.sh"
fi

# ── deploy override ────────────────────────────────────────────────────────────
echo "==> Deploying app override..."
_devicectl_copy "$APP_SRC" "$OVERRIDE_DST"
echo "    $APP_SRC → $OVERRIDE_DST"

# ── deploy a single named app + its siblings ───────────────────────────────────
if [[ -n "$APP_ARG" ]]; then
    SCRIPT_SRC="$APPS_DIR/${APP_ARG}.py"
    if [[ ! -f "$SCRIPT_SRC" ]]; then
        echo "ERROR: app not found: $SCRIPT_SRC" >&2
        exit 1
    fi
    echo "==> Deploying app: ${APP_ARG}.py → Documents/${APP_ARG}.py"
    _devicectl_copy "$SCRIPT_SRC" "Documents/${APP_ARG}.py"
    # Also push sibling helper files from apps/
    for dep in "$APPS_DIR"/*.py; do
        dep_name=$(basename "$dep")
        if [[ "$dep_name" != "${APP_ARG}.py" ]]; then
            _devicectl_copy "$dep" "Documents/${dep_name}" 2>/dev/null || true
        fi
    done
fi

# ── deploy all apps ────────────────────────────────────────────────────────────
if [[ $DEPLOY_APPS -eq 1 ]]; then
    echo "==> Deploying all apps/*.{py,qml} → Documents/"
    for f in "$APPS_DIR"/*.py "$APPS_DIR"/*.qml; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f")
        echo "    $name"
        _devicectl_copy "$f" "Documents/${name}"
    done
fi

# ── write launch request ───────────────────────────────────────────────────────
if [[ $LAUNCH -eq 1 ]] && [[ -n "$APP_ARG" || -n "$FILE_ARG" ]]; then
    REQUEST="${APP_ARG:-$FILE_ARG}"
    echo "==> Writing launch request: '$REQUEST'"
    TMPFILE=$(mktemp /tmp/launch_request.XXXXXX)
    printf '%s' "$REQUEST" > "$TMPFILE"
    _devicectl_copy "$TMPFILE" "Documents/_launch_request.txt"
    rm -f "$TMPFILE"
fi

# ── launch ─────────────────────────────────────────────────────────────────────
if [[ $LAUNCH -eq 1 ]]; then
    echo "==> Launching..."
    xcrun devicectl device process launch \
        --device "$DEVICE_UUID" \
        --console \
        --terminate-existing \
        "$BUNDLE_ID" 2>&1 \
        | grep -v "^objc\[" | grep -v "implemented in both"
fi
