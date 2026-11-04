#!/usr/bin/env bash
# The UDFs a ClickHouse running natively on macOS starts (enve.cue's clickhouse preStart, under
# exclusive.sh's lock). posthog/user_scripts commits Linux binaries only: upstream runs ClickHouse
# in a Linux container everywhere. run_udf.sh (patches/0009) starts <name>_darwin_<arch> on macOS,
# which this builds from the checkout's sources, as upstream's build scripts do for Linux:
# clickhouse-udfs/util's Go UDFs (scripts/build.sh's flags) and funnel-udf's aggregate_funnel
# (`cargo build --release`). Only the unversioned ones: outside GitHub Actions the code calls those
# (posthog/hogql/functions/udfs.py); the versioned directories hold older releases' binaries.
# Builds only when the sources differ from the last build's, so every later start, and every
# shard's instance, finds it done. Nothing to do on Linux.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || exit 0
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$self")/../.."

arch=$(uname -m)
out=posthog/user_scripts
go_udfs=(decompress_udf json_drop_keys_udf json_clean_posthog_event_properties_udf json_strip_empty_strings_and_nulls_udf)
stamp=".enact/state/clickhouse/host-udfs-$arch.sha256"

digest=$(find clickhouse-udfs/util funnel-udf "$self" -type f \
    -not -path 'funnel-udf/target/*' -not -path '*/testdata/*' -print0 \
    | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
built=1
for name in "${go_udfs[@]}" aggregate_funnel; do
    [ -x "$out/${name}_darwin_$arch" ] || built=0
done
if [ "$built" = 1 ] && [ "$(cat "$stamp" 2>/dev/null)" = "$digest" ]; then exit 0; fi

echo "Building the ClickHouse UDFs for darwin/$arch into $out" >&2
root=$PWD
trap 'rm -f "$root/$out"/.*_darwin_"$arch".tmp' EXIT
for name in "${go_udfs[@]}"; do
    (cd clickhouse-udfs/util && CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
        -o "$root/$out/.${name}_darwin_$arch.tmp" "./cmd/$name")
done
# Its own target dir, whatever CARGO_TARGET_DIR the caller's environment holds.
cargo build --release --locked --manifest-path funnel-udf/Cargo.toml --target-dir funnel-udf/target
cp funnel-udf/target/release/funnels "$out/.aggregate_funnel_darwin_$arch.tmp"
# Renamed into place only now: a pooled UDF process copies its binary on start (run_udf.sh), and a
# half-built set never takes the stamp.
for name in "${go_udfs[@]}" aggregate_funnel; do
    mv -f "$out/.${name}_darwin_$arch.tmp" "$out/${name}_darwin_$arch"
done
mkdir -p "$(dirname "$stamp")"
printf '%s\n' "$digest" >"$stamp"
