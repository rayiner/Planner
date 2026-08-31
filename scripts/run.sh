#!/usr/bin/env bash
#
# Build and run Planner from the command line.
#
#   scripts/run.sh              build Release, launch detached
#   scripts/run.sh -a           launch in the foreground with logs in the terminal
#   scripts/run.sh -n           launch the existing build without rebuilding
#   scripts/run.sh -d           use the Debug configuration
#   scripts/run.sh -c           clean first
#
set -euo pipefail

PROJECT="Planner.xcodeproj"
SCHEME="Planner"
CONFIGURATION="Release"
ATTACHED=0
BUILD=1
CLEAN=0
VERBOSE=0

usage() {
    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  -a, --attached   Run in the foreground; stdout/stderr stream here, Ctrl-C quits.
                   Without this the app is launched detached, like double-clicking it.
  -n, --no-build   Skip the build and launch whatever is already built.
  -d, --debug      Build and run the Debug configuration instead of Release.
  -c, --clean      Clean the configuration before building.
  -v, --verbose    Show full xcodebuild output instead of just warnings and errors.
  -h, --help       Show this help.

Any arguments after -- are passed through to the app.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--attached) ATTACHED=1; shift ;;
        -n|--no-build) BUILD=0; shift ;;
        -d|--debug)    CONFIGURATION="Debug"; shift ;;
        -c|--clean)    CLEAN=1; shift ;;
        -v|--verbose)  VERBOSE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        *)             echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
APP_ARGS=("$@")

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ ! -d "$PROJECT" ]]; then
    echo "error: $PROJECT not found; run this from anywhere inside the repo." >&2
    exit 1
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

echo "==> $APP"

if [[ $ATTACHED -eq 1 ]]; then
    # Exec the binary directly so logs land in this terminal and Ctrl-C quits it.
    # The +"..." guard is required: under `set -u`, bash 3.2 (what macOS ships)
    # treats "${arr[@]}" on an empty array as an unbound variable.
    exec "$APP/Contents/MacOS/$SCHEME" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
else
    # Detached, the way Finder launches it. -n forces a new instance even if one
    # is already running, which is what you want when testing a fresh build.
    open -n "$APP" ${APP_ARGS[0]+--args "${APP_ARGS[@]}"}
fi
