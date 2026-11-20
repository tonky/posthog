#!/usr/bin/env bash
# `vitest <args…>` from the package's directory, as `pnpm exec vitest` runs it.
#
# Recording modes:
# - ENACT_ATTRIBUTION_FILE set (inner call from `enact trace run --attribution`):
#   runs vitest with isolated forked workers and enact's shared `vitest-attribution.mjs`
#   reporter so every Node-pool test file is attributed in a single traced invocation.
# - ENACT_FOOTPRINT_DIR set on Linux (`recorder: "own_linux"`):
#   partitions wanted Node-pool targets (attributed in one run) from Cloudflare workerd
#   targets (`tests/workers/*`, traced individually because workerd cannot run in `--pool=forks`)
#   and non-wanted targets (run plain), writing reach maps into `$ENACT_FOOTPRINT_DIR`.
# - ENACT_NODE_COVERAGE_DIR set (under `recorder: "trace"` + `--node-functions`, e.g. `agent:test`):
#   adds `node_marker.mjs` so each worker ends its file's Node coverage cleanly.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo="$(cd "${here}/../.." && pwd -P)"

if [ -n "${ENACT_ATTRIBUTION_FILE:-}" ]; then
    vitest_attr="${ENACT_RECORDERS_DIR:+$ENACT_RECORDERS_DIR/js/vitest-attribution.mjs}"
    if [ -z "$vitest_attr" ] || [ ! -f "$vitest_attr" ]; then
        vitest_attr="${repo}/.enact/state/recorders/js/vitest-attribution.mjs"
    fi
    if [ ! -f "$vitest_attr" ]; then
        echo "✗ vitest.sh: vitest-attribution.mjs not found (ENACT_RECORDERS_DIR=${ENACT_RECORDERS_DIR:-unset})" >&2
        exit 2
    fi
    exec pnpm exec vitest "$@" --no-cache --pool=forks --isolate --reporter=default "--reporter=${vitest_attr}"
fi

if [ -n "${ENACT_FOOTPRINT_DIR:-}" ] && [ "${ENACT_VITEST_FORCE_TRACE:-$(uname -s)}" = Linux ]; then
    out_dir="$ENACT_FOOTPRINT_DIR"
    wanted_file="${ENACT_FOOTPRINT_TARGETS:-}"
    unset ENACT_FOOTPRINT_DIR ENACT_FOOTPRINT_TARGETS

    enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}"
    if [ -z "$enact" ]; then
        echo "✗ vitest.sh: no enact on PATH (set ENACT_EXE or ENACT_BIN)" >&2
        exit 2
    fi

    pwd_real="$(pwd -P)"
    pkg_rel=""
    if [ "$pwd_real" != "$repo" ] && [[ "$pwd_real" == "$repo/"* ]]; then
        pkg_rel="${pwd_real#"$repo"/}"
    fi

    base_args=()
    targets=()
    has_config=0
    subcmd_seen=0
    expect_val=0
    for arg in "$@"; do
        if [ "$expect_val" -eq 1 ]; then
            base_args+=("$arg")
            expect_val=0
            continue
        fi
        if [ "$subcmd_seen" -eq 0 ] && [[ "$arg" != -* ]]; then
            base_args+=("$arg")
            subcmd_seen=1
            continue
        fi
        case "$arg" in
            --config | -c)
                has_config=1
                base_args+=("$arg")
                expect_val=1
                ;;
            --config=* | -c=*)
                has_config=1
                base_args+=("$arg")
                ;;
            --project | -t | --testNamePattern | --reporter | --pool | --maxWorkers | --shard | --dir | --root)
                base_args+=("$arg")
                expect_val=1
                ;;
            -*)
                base_args+=("$arg")
                ;;
            *)
                targets+=("$arg")
                ;;
        esac
    done

    is_wanted() {
        local rel="$1"
        [ -n "$wanted_file" ] || return 0
        local clean="${rel#./}"
        clean="${clean%%::*}"
        local repo_target="${pkg_rel:+$pkg_rel/}${clean}"
        awk -v a="$repo_target" -v b="$clean" '
            $0 == a || index($0, a "::") == 1 || $0 == b || index($0, b "::") == 1 { found = 1; exit }
            END { exit !found }
        ' "$wanted_file"
    }

    plain_targets=()
    attr_targets=()
    workerd_targets=()
    attr_full=0
    node_extra=()

    if [ "${#targets[@]}" -eq 0 ]; then
        want_pkg=1
        if [ -n "$wanted_file" ] && [ -n "$pkg_rel" ]; then
            if ! awk -v p="${pkg_rel}/" 'index($0, p) == 1 { found = 1; exit } END { exit !found }' "$wanted_file"; then
                want_pkg=0
            fi
        fi
        if [ "$want_pkg" -eq 0 ]; then
            exec "${BASH_SOURCE[0]}" "$@"
        fi
        if [ "$has_config" -eq 0 ] && [ -f vitest.workers.config.mts ] && [ -d tests/workers ]; then
            attr_full=1
            node_extra=(--project unit)
            while IFS= read -r wf; do
                [ -n "$wf" ] || continue
                wf="${wf#./}"
                if is_wanted "$wf"; then
                    workerd_targets+=("$wf")
                else
                    plain_targets+=("$wf")
                fi
            done < <(find tests/workers -type f -name '*.test.ts' | sort)
        else
            attr_full=1
        fi
    else
        for t in "${targets[@]}"; do
            clean="${t#./}"
            if ! is_wanted "$t"; then
                plain_targets+=("$t")
            elif [[ "$clean" == tests/workers/* ]]; then
                workerd_targets+=("$t")
            else
                attr_targets+=("$t")
            fi
        done
    fi

    status=0
    if [ "${#plain_targets[@]}" -gt 0 ]; then
        "${BASH_SOURCE[0]}" "${base_args[@]}" "${plain_targets[@]}" || status=$?
    fi

    if [ "$attr_full" -eq 1 ] || [ "${#attr_targets[@]}" -gt 0 ]; then
        work="$(mktemp -d "${TMPDIR:-/tmp}/enact-vitest-attr.XXXXXX")"
        trap 'rm -rf "$work"' EXIT
        map_in="$work/attr.json"
        attr_jsonl="$work/attr.jsonl"
        echo "🎙️  [vitest] tracing ${attr_targets[*]:+selected }Node vitest target(s) with vitest-attribution.mjs"
        "$enact" trace run --no-fingerprint --node-functions --reach-file "$map_in" --attribution "$attr_jsonl" -- \
            "${BASH_SOURCE[0]}" "${base_args[@]}" ${node_extra[@]+"${node_extra[@]}"} ${attr_targets[@]+"${attr_targets[@]}"} \
            || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
        if [ -s "$map_in" ]; then
            mkdir -p "$out_dir"
            out_file="${out_dir}/vitest-attr-${ENACT_SHARD_INDEX:-1}-$$.json"
            python3 -I -X utf8 -c '
import json, os, sys
src, dst, wanted_path, pkg_rel = sys.argv[1:5]
with open(src, encoding="utf-8") as f:
    data = json.load(f)
want = None
if wanted_path and os.path.isfile(wanted_path):
    with open(wanted_path, encoding="utf-8") as f:
        want = [l.strip() for l in f if l.strip()]
def keep(target):
    if want is None:
        return True
    for w in want:
        if w == target or w.startswith(target + "::") or w.startswith(target + "/"):
            return True
    return False
if want is not None:
    for key in ("targets", "target_service_deps"):
        obj = data.get(key)
        if isinstance(obj, dict):
            data[key] = {k: v for k, v in obj.items() if keep(k)}
data["outcomes"] = True
part = dst + ".part"
with open(part, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
os.replace(part, dst)
' "$map_in" "$out_file" "$wanted_file" "$pkg_rel" || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
        else
            echo "⚠️  [vitest] attribution trace wrote no map; running untraced" >&2
            "${BASH_SOURCE[0]}" "${base_args[@]}" ${node_extra[@]+"${node_extra[@]}"} ${attr_targets[@]+"${attr_targets[@]}"} \
                || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
        fi
    fi

    if [ "${#workerd_targets[@]}" -gt 0 ]; then
        mkdir -p "$out_dir"
        n=0
        for wt in "${workerd_targets[@]}"; do
            n=$((n + 1))
            clean="${wt#./}"
            repo_target="${pkg_rel:+$pkg_rel/}${clean%%::*}"
            echo "🎙️  [vitest] tracing workerd target ${repo_target}"
            "$enact" trace run --no-fingerprint --outcomes --reach-file "${out_dir}/vitest-worker-${n}-$$.json" \
                -t "$repo_target" -- "${BASH_SOURCE[0]}" "${base_args[@]}" "$wt" \
                || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
        done
    fi

    exit "$status"
fi

reporters=()
if [ -n "${ENACT_NODE_COVERAGE_DIR:-}" ]; then
    reporters=(--reporter=default "--reporter=${here}/node_marker.mjs")
fi
exec pnpm exec vitest "$@" ${reporters[@]+"${reporters[@]}"}
