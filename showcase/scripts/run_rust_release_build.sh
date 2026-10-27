#!/usr/bin/env bash
# ci-rust.yml's "Build Rust" job: a release build of the crates a change affects, as each of
# upstream's shards runs it (`cargo build -p <crate>... --locked --release`, on the system
# OpenSSL rather than the vendored one).
#
#   run_rust_release_build.sh [crate...]
#
# The crates are rust_services:build's targets: names (rust_affected_crates.sh, upstream's
# determinator) or manifests, as its suite lists them (`--targets rust/<crate>/Cargo.toml`,
# relative to the caller's directory). Without any (a full run), every workspace crate:
# upstream's rebuild-all.
# Upstream then strips the binaries in target/release for its cache; that checks nothing and
# isn't done here.
set -euo pipefail
caller="$PWD"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=rust_ci_env.sh
source showcase/scripts/rust_ci_env.sh

packages=()
if [ "$#" -eq 0 ]; then
    packages=(--workspace)
    echo "Building every workspace crate (release)"
else
    for c in "$@"; do
        case "$c" in
        */Cargo.toml)
            # The manifest's [package] name.
            manifest=$c
            c=$(cd "$caller" && awk -F'"' '/^\[/ { in_package = ($0 == "[package]") }
                in_package && /^name *=/ { print $2; exit }' "$manifest")
            [ -n "$c" ] || { echo "✗ run_rust_release_build.sh: no [package] name in $manifest" >&2; exit 1; }
            ;;
        esac
        packages+=(-p "$c")
    done
    echo "Building $# crate(s) (release): $*"
fi

cd rust
exec env "${unset_args[@]}" OPENSSL_NO_VENDOR=1 cargo build "${packages[@]}" --locked --release
