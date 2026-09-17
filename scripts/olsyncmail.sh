#!/usr/bin/env bash
#
# Build the olsyncmail helper, which Recent Mail runs as a daemon.
#
# Sourced by scripts/package.sh and scripts/run.sh rather than run on its own:
# the Xcode project copies target/release/olsyncmail into the bundle, so the
# crate has to be built *before* xcodebuild or the app ships whatever was there
# last time.
#
#   MAILINDEX_DIR   path to the mailindex crate; default ../mailindex
#   SKIP_HELPER=1   leave the existing binary alone (a Swift-only edit)

build_olsyncmail() {
    local dir="${MAILINDEX_DIR:-../mailindex}"

    if [[ "${SKIP_HELPER:-0}" == "1" ]]; then
        echo "==> Skipping olsyncmail (SKIP_HELPER=1)"
        return 0
    fi

    if [[ ! -f "$dir/Cargo.toml" ]]; then
        echo "error: the mailindex crate is not at $dir (set MAILINDEX_DIR)." >&2
        echo "  Recent Mail runs its olsyncmail binary; without it the pane stays empty." >&2
        return 1
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        echo "error: cargo not found; olsyncmail is built with it." >&2
        return 1
    fi

    echo "==> cargo build --release (olsyncmail)"
    cargo build --release --manifest-path "$dir/Cargo.toml" --bin olsyncmail

    if [[ ! -x "$dir/target/release/olsyncmail" ]]; then
        echo "error: expected the helper at $dir/target/release/olsyncmail" >&2
        return 1
    fi
}
