#!/usr/bin/env bash
# The Rust crates a change affects, by upstream's own determinator (rust/affected-services,
# as .github/actions/rust-compute-affected runs it): rust_services:build's target_scope
# command, run in the job after its prepare (select_in_job: it builds affected-services).
#
#   rust_affected_crates.sh <changed file>...
#
# Changed files are repository-relative (enact's {changed_files}); prints one crate per
# line. Upstream diffs the old cargo graph against the new (--base-ref); given files, the
# determinator has no old graph, so a Cargo.lock change marks every crate. A change marking
# none (rust/bin/, a fixture outside every crate) builds every crate, as ci-rust.yml's shard
# step does with an empty affected set ("Full build"): the determinator's every-crate set.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../rust"
[ "$#" -gt 0 ] || exit 0

# `--output crates` prints a JSON array of crate names (no quotes or commas in a name).
affected() {
    enve run --locked -q -- cargo run -q --release --locked -p affected-services -- "$@" --output crates |
        tr -d '[]" \n' | tr ',' '\n' | sed '/^$/d'
}
crates=$(printf '%s\n' "$@" | affected --stdin)
[ -n "$crates" ] || crates=$(affected --files rust/Cargo.lock)
printf '%s\n' "$crates"
