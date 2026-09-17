#!/usr/bin/env bash
#
# Copy the Release build of Planner into build/ in the source directory.
#
#   scripts/package.sh          build Release, copy to build/Planner.app
#   scripts/package.sh -n       copy the existing build without rebuilding
#   scripts/package.sh -c       clean first
#
set -euo pipefail

PROJECT="Planner.xcodeproj"
SCHEME="Planner"
CONFIGURATION="Release"
DEST_DIR="build"
BUILD=1
CLEAN=0
VERBOSE=0

usage() {
    sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  -n, --no-build   Skip the build and copy whatever is already built.
  -c, --clean      Clean the configuration before building.
  -v, --verbose    Show full xcodebuild output instead of just warnings and errors.
  -h, --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--no-build) BUILD=0; shift ;;
        -c|--clean)    CLEAN=1; shift ;;
        -v|--verbose)  VERBOSE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ ! -d "$PROJECT" ]]; then
    echo "error: $PROJECT not found; run this from anywhere inside the repo." >&2
    exit 1
fi

# Recent Mail shells out to olsyncmail, which a build phase copies into the
# bundle. Build the crate first so the copy picks up this revision.
source scripts/olsyncmail.sh
if [[ $BUILD -eq 1 ]]; then
    build_olsyncmail
fi

# -allowProvisioningUpdates: every build signs for real now (the iCloud
# entitlements make a development certificate mandatory, not optional), so a
# fresh checkout needs Xcode to fetch or renew the provisioning profile rather
# than failing with "No profiles for 'com.rihscb.Planner' were found".
xcode() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -allowProvisioningUpdates "$@"
}

# Ask xcodebuild where the product lands rather than hardcoding a DerivedData
# path, which is keyed on a hash of the project location.
read_setting() {
    xcode -showBuildSettings 2>/dev/null | sed -n "s/^ *$1 = //p" | head -1
}

if [[ $CLEAN -eq 1 ]]; then
    echo "==> Cleaning $CONFIGURATION"
    xcode clean >/dev/null
fi

if [[ $BUILD -eq 1 ]]; then
    echo "==> Building $CONFIGURATION"
    if [[ $VERBOSE -eq 1 ]]; then
        xcode build
    else
        # Keep the diagnostics, drop the command echoes. The pipe would swallow
        # xcodebuild's exit status, so check PIPESTATUS.
        set +e
        xcode build 2>&1 | grep -E "error:|warning:|\*\* (BUILD|CLEAN)" | sort -u
        status=${PIPESTATUS[0]}
        set -e
        if [[ $status -ne 0 ]]; then
            echo "error: build failed (re-run with -v for full output)" >&2
            exit "$status"
        fi
    fi
fi

PRODUCTS_DIR="$(read_setting BUILT_PRODUCTS_DIR)"
APP_NAME="$(read_setting FULL_PRODUCT_NAME)"
APP="$PRODUCTS_DIR/$APP_NAME"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP does not exist. Build it first (drop -n)." >&2
    exit 1
fi

DEST="$DEST_DIR/$APP_NAME"
mkdir -p "$DEST_DIR"

# Delete rather than copy over the top: ditto merges into an existing bundle, so
# resources dropped since the last copy would linger and still be loadable.
rm -rf "$DEST"

# ditto, not cp -R: it preserves the extended attributes and the code signature
# that macOS checks before it will launch the bundle.
ditto "$APP" "$DEST"

# A bundle that copied but no longer validates launches to a crash dialog with
# no useful explanation, so find out here instead.
if ! codesign --verify --deep "$DEST" 2>/dev/null; then
    echo "warning: signature does not validate at $DEST" >&2
fi

echo "==> $DEST"
