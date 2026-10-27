#!/usr/bin/env bash
# What the ci-rust*.yml jobs' runners (run_rust_tests.sh, run_personhog_gate.sh,
# run_flags_integration.sh) share. Source it from the checkout's root.
#
# `unset_args`: `env` arguments removing the profile's application settings, which the
# backend's jobs read and upstream's Rust jobs never set: with them, the crates' defaults
# tests saw this machine's values (feature-flags' test_default_config: REDIS_URL). The
# toolchain's and the clock's stay. Run the job's commands as `env "${unset_args[@]}" ...`.
keep=" TZ PGTZ npm_config_manage_package_manager_versions COREPACK_ENABLE_DOWNLOAD_PROMPT "
unset_args=()
while IFS= read -r name; do
    [[ "$keep" == *" $name "* ]] || unset_args+=(-u "$name")
done < <(enve cue export -q -e profiles.dev.environment enve.cue | jq -r 'keys[]')
[ "${#unset_args[@]}" -gt 0 ] || { echo "Read no environment from enve.cue" >&2; exit 1; }

# A CI build edits nothing to recompile incrementally, and the workspace's incremental state
# is half its target dir (28G of 65G on the Mac). The jobs share one target dir.
export CARGO_INCREMENTAL=0
# No debuginfo (upstream's dev default is full): the workspace's ~330 test executables hold
# a copy of it each (~60G of target with it on Linux, 31G without). A panic still names its
# file and line (its Location is compiled in); backtrace frames name functions only. Every
# job building in the workspace's target dir sets the same, or each builds its own copies.
export CARGO_PROFILE_DEV_DEBUG=0
export RUST_BACKTRACE=1

# `cargo build --config "$(cd rust && rust_no_assertions)"`: the workspace's own crates
# without debug assertions or overflow checks, as upstream's images, for the runners of a
# live service (run_flags_integration.sh, live_posthog.sh). A RUSTFLAGS override would do it
# by replacing .cargo/config.toml's rustflags (--cfg tokio_unstable, macOS's lld) and
# compiling every dependency a second time; the profile keeps the dependencies the other
# Rust jobs build in the shared target dir. It prints a config file in the target dir (a
# --config value can't be a table).
rust_no_assertions() {
    local meta file
    meta="$(cargo metadata --no-deps --format-version 1)" &&
        file="$(jq -r .target_directory <<<"$meta")/no-assertions.toml" &&
        mkdir -p "${file%/*}" &&
        jq -r '.packages[].name | "[profile.dev.package.\"\(.)\"]",
            "debug-assertions = false", "overflow-checks = false"' <<<"$meta" >"$file.$$" &&
        mv "$file.$$" "$file" && echo "$file"
}
