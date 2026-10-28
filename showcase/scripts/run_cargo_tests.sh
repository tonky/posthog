#!/usr/bin/env bash
# The tests of a cargo workspace of its own (cli/, funnel-udf/), as its workflow's `cargo
# test [option...]`, by test binary:
#
#   run_cargo_tests.sh <workspace dir> [cargo test option...] -- [test binary root file...]
#
# The workspace directory is repository-relative. Root files are relative to the caller's
# directory or the repository (cli/src/lib.rs for the library's unit tests, and its doctests,
# cli/tests/<x>.rs, funnel-udf/src/main.rs for a binary's); none: every one.
#
# In a recording run on Linux ($ENACT_FOOTPRINT_DIR), each test binary $ENACT_FOOTPRINT_TARGETS
# names (every one that runs without it) is built, then runs alone under `enact trace run`
# without cargo, as cargo runs it (from the package's directory): a traced cargo would hold what
# it reads checking the build is fresh. rust_footprint.py adds what the binary was built from,
# as run_rust_tests.sh's.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
workspace="${1:?usage: run_cargo_tests.sh <workspace dir> [cargo test option...] -- [root file...]}"
shift
options=()
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do options+=("$1"); shift; done
[ "$#" -eq 0 ] || shift
if [ "$#" -gt 0 ]; then
    # Repository-relative from here on.
    given=()
    for target in "$@"; do
        dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || dir="$(dirname "$target")"
        given+=("${dir#"$root"/}/$(basename "$target")")
    done
    set -- "${given[@]}"
fi
cd "$root/$workspace"
if [ "$#" -eq 0 ] && [ -z "${ENACT_FOOTPRINT_DIR:-}" ]; then
    exec cargo test ${options[@]+"${options[@]}"}
fi

# Each test binary's root file, with the cargo test option selecting it and its package: the
# libraries', the binaries' and the integration tests'.
metadata="$(cargo metadata --no-deps --format-version 1)"
files=() selectors=() packages=() dirs=()
while IFS=$'\t' read -r file selector package dir; do
    files+=("$file") selectors+=("$selector") packages+=("$package") dirs+=("$dir")
done < <(jq -r --arg ws_dir "$workspace" '(.workspace_root + "/") as $ws | .packages[]
    | .name as $package | (.manifest_path | rtrimstr("/Cargo.toml")) as $dir | .targets[]
    | select(.test and ((."required-features" // []) | length == 0))
    | [$ws_dir + "/" + (.src_path | ltrimstr($ws)),
       (if .kind[0] == "test" then "--test=\(.name)" elif .kind[0] == "bin" then "--bin=\(.name)" else "--lib" end),
       $package, $dir]
    | @tsv' <<<"$metadata")
index_of() { # <root file>
    local i
    for i in "${!files[@]}"; do [ "${files[$i]}" = "$1" ] && echo "$i" && return 0; done
    echo "✗ run_cargo_tests.sh: $1 is no test binary's root file" >&2
    return 64
}
[ "$#" -gt 0 ] || set -- "${files[@]}"
run=()
for file in "$@"; do
    i="$(index_of "$file")"
    run+=("${selectors[$i]}")
done

# Recording: the binaries to trace, on Linux only (enact's tracer is seccomp's).
traced=() plain=()
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ] && [ "$(uname -s)" = Linux ]; then
    wanted_list="$(cat "${ENACT_FOOTPRINT_TARGETS:-/dev/null}")"
    [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] || wanted_list="$(printf '%s\n' "$@")"
    for file in "$@"; do
        case $'\n'"$wanted_list"$'\n' in
            *$'\n'"$file"$'\n'*) traced+=("$file") ;;
            *) plain+=("${selectors[$(index_of "$file")]}") ;;
        esac
    done
else
    plain=("${run[@]}")
fi

status=0
[ "${#plain[@]}" -eq 0 ] || cargo test ${options[@]+"${options[@]}"} "${plain[@]}" || status=1
if [ "${#traced[@]}" -gt 0 ]; then
    traces="$(mktemp -d)"
    trap 'rm -rf "$traces"' EXIT
    build=() passed=()
    for file in "${traced[@]}"; do build+=("${selectors[$(index_of "$file")]}"); done
    if cargo test ${options[@]+"${options[@]}"} --no-run --message-format json "${build[@]}" >"$traces/artifacts.jsonl" &&
        cargo metadata --format-version 1 >"$traces/metadata.json"; then
        for file in "${traced[@]}"; do
            i="$(index_of "$file")"
            # The test executable cargo built from the root file.
            exe="$(jq -r --arg src "$root/$file" 'select(.reason == "compiler-artifact" and .profile.test
                and .executable != null and .target.src_path == $src) | .executable' "$traces/artifacts.jsonl" | head -n 1)"
            if [ -z "$exe" ]; then
                echo "✗ run_cargo_tests.sh: cargo built no test binary of $file" >&2
                status=1
                continue
            fi
            if (cd "${dirs[$i]}" && "$ENACT_EXE" trace run --target "$file" --outcomes --no-fingerprint \
                --reach-file "$traces/rust_$(printf '%s' "$file" | tr '/' '_').json" -- \
                env CARGO_MANIFEST_DIR="${dirs[$i]}" CARGO_PKG_NAME="${packages[$i]}" "$exe"); then
                passed+=(--passed "$file")
            else
                status=1
            fi
        done
        maps=()
        for map in "$traces"/rust_*.json; do [ -e "$map" ] && maps+=("$map"); done
        python3 "$root/showcase/scripts/rust_footprint.py" --repo "$root" --artifacts "$traces/artifacts.jsonl" \
            --metadata "$traces/metadata.json" --recorder "rust_footprint.py/3" --out "$ENACT_FOOTPRINT_DIR" \
            ${passed[@]+"${passed[@]}"} ${maps[@]+"${maps[@]}"} || status=1
    else
        status=1
    fi
fi
# As cargo test's, a library's doctests when its unit tests ran.
for file in "$@"; do
    i="$(index_of "$file")"
    if [ "${selectors[$i]}" = --lib ]; then
        cargo test ${options[@]+"${options[@]}"} --doc -p "${packages[$i]}" || status=1
    fi
done
exit "$status"
