#!/usr/bin/env bash
# Shared provenance check. Enve may expose both /nix/store and physical user paths.
# Locked enve validates the closures; this guard rejects fallback host executables.
# Print a resolved path relative to whichever store root holds it
# (<package>/<path>), or fail. The same store object is reachable under
# several roots: enve mounts the user store at /nix/store inside its
# environment, and a nested enve run resolves tools through that alias.
store_relative() {
    local resolved root canonical
    resolved=$(realpath "$1") || fail "cannot resolve $1"
    local roots=("${ENVE_STORE_DIR:-${NIX_STORE_DIR:-}}" /nix/store
                 "${XDG_DATA_HOME:-$HOME/.local/share}/enve/store" "/tmp/enve-$EUID/store")
    for root in "${roots[@]}"; do
        [[ "$root" == /* && "$root" != / ]] || continue
        canonical=$(realpath -m "$root") || continue
        [[ "$canonical" != / ]] || continue
        case "$resolved" in
            "$canonical"/*)
                printf '%s\n' "${resolved#"$canonical"/}"
                return 0
                ;;
        esac
    done
    return 1
}
owned_tool() {
    local selected resolved relative
    selected=$(command -v "$1") || fail "enve did not provide $1"
    resolved=$(realpath "$selected") || fail "cannot resolve $1"
    relative=$(store_relative "$resolved") || fail "$1 resolved outside the enve store: $resolved"
    # Accept package bin/ and libexec/.../bin/ symlink targets.
    relative=${relative#*/}
    if [[ "$relative" == bin/* || "$relative" == */bin/* ]]; then
        printf '%s\n' "$resolved"
        return 0
    fi
    fail "$1 resolved outside the enve store: $resolved"
}
