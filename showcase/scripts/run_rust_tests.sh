#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root/rust"

export OPENSSL_NO_VENDOR=1
export SQLX_OFFLINE=true
unset LD_LIBRARY_PATH
if [ -z "${PROTOC:-}" ]; then
    protoc="$(which protoc 2>/dev/null || fd -t f '^protoc$' /nix/store ~/.local/share/enve/store 2>/dev/null | head -1)"
    if [ -n "$protoc" ]; then
        export PROTOC="$protoc"
        inc="$(dirname "$(dirname "$protoc")")/include"
        if [ -d "$inc" ]; then
            export PROTOC_INCLUDE="$inc"
        fi
    fi
fi

crates=()
for f in "$@"; do
    case "$f" in
        rust/capture/*) crates+=("capture") ;;
        rust/common/compression/*) crates+=("common-compression") ;;
        rust/feature-flags/*) crates+=("feature-flags") ;;
        rust/common/hogvm/*) crates+=("hogvm") ;;
        rust/cohort-core/*) crates+=("cohort-core") ;;
        rust/cymbal/*) crates+=("cymbal") ;;
        rust/common/*)
            sub="$(echo "$f" | cut -d/ -f3)"
            if [ -d "common/$sub" ]; then
                crates+=("common-$sub")
            fi
            ;;
        rust/*)
            pkg="$(echo "$f" | cut -d/ -f2)"
            if [ -f "$pkg/Cargo.toml" ]; then
                crates+=("$pkg")
            fi
            ;;
    esac
done

args=()
if [ "${#crates[@]}" -gt 0 ]; then
    unique_crates=($(printf "%s\n" "${crates[@]}" | sort -u))
    for c in "${unique_crates[@]}"; do
        args+=("-p" "$c")
    done
else
    args=("-p" "common-compression" "-p" "capture")
fi
exec cargo test "${args[@]}" --lib -- --skip test_repository
