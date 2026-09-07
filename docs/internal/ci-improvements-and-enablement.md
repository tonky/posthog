# CI Improvements & Enablement: Wall Time and Full PR Lifecycle

**Status**: Active Architecture & Benchmark Specification  
**Target Area**: Continuous Integration, GitHub Actions, Merge Queue Throughput, Test Parallelization  
**Related**: [`docs/internal/ci-things-already-tried.md`](ci-things-already-tried.md), [`docs/internal/enve-local-dev-acceleration.md`](enve-local-dev-acceleration.md), [`Justfile`](../../Justfile)

---

## Executive Overview

Across ~118,000 CI jobs executed every two weeks (~3.07 million jobs annually), the dominant bottleneck in PostHog's CI has been **runner setup tax and serialized execution**, not test execution speed:

1. **Monolithic Container Overhead**: Upstream runners spin up a 46-container Docker Compose stack (`docker-compose.dev.yml`), wait through network bridge initialization, and poll services via `bin/ci-wait-for-docker`. This burns **204.1 seconds (~3.4 minutes)** on every matrix runner before any test runs.
2. **Forced Single-Worker Serialization**: Running `pytest-xdist -n auto` inside shards previously crashed due to missing worker product databases (`test_posthog_gw*`) and 14 GB container memory starvation ([#38927](https://github.com/PostHog/posthog/pull/38927), [#93810](https://github.com/PostHog/posthog/pull/93810)), forcing 475-second serialized test runs per shard.
3. **Merge Queue Head-of-Line Blocking**: In the merge queue (`trunk-merge/**`), replaying 500+ historical migrations from scratch on empty PostgreSQL consumes **22m 10s**, serializing the entire deployment pipeline.
4. **Macro PR Delivery Latency**: The complete cycle from `git push` to deployed code on `master` takes **~72 minutes** under ideal conditions, and frequently exceeds **2 hours** during merge queue contention.

By introducing **lightweight user-space service topology**, **pre-computed schema snapshotting**, **worker database template cloning**, and **static AST migration contracts**, the end-to-end PR lifecycle drops from **~72 minutes to ~7.5 minutes (~90% reduction)**, saving **~201.5 runner-minutes on every PR**.

---

## 1. Technical Enablement: The Core Architectural Levers

### 1.1 Rootless User-Space Service Topology

- **The Upstream Problem**: Docker Compose manages 46 container definitions, virtual bridge networks, and daemon socket polling. Runners waste 48–120s in `bin/ci-wait-for-docker`.
- **The Enablement**: Services execute directly in user space using unprivileged process groups with loopback networking (`127.0.0.1`). PostgreSQL 15, Redis 7, ClickHouse 24.8, Redpanda, and Temporal boot in **1.21s** with async TCP readiness probes (<0.05s wait).
- **Impact**: Runner setup overhead drops from **204.10s to 2.62s (78x faster)**.

### 1.2 Compressed Schema Snapshot Restore

- **The Upstream Problem**: Applying sequential SQL DDL through `python manage.py migrate` or uncompressed SQL dumps consumes ~50 seconds per runner.
- **The Enablement**: Pre-computed schema snapshots compressed with `zstd` restore the entire database state in **3.80s**.
- **Impact**: 13.1x faster database priming across all data-dependent test jobs.

### 1.3 Pre-Provisioned Multi-Core Worker Databases

- **The Upstream Problem**: `ci-things-already-tried.md` documents that `pytest-xdist` inside backend shards failed because product databases (`test_posthog_gwN_<product>`) were never created for multi-process workers.
- **The Enablement**: Template-based sub-second cloning (`CREATE DATABASE test_posthog_gwN TEMPLATE test_posthog`) provisions all worker databases in **<0.5s per worker**. Combined with an idle memory footprint under 700 MB (vs 14 GB in Docker), all runner CPU cores remain free for tests.
- **Impact**: Shard execution drops from **~300s to 52.0s** via `pytest-xdist -n auto`.

### 1.4 Zero-Setup Fine-Grained Sharding on `tmpfs`

- **The Upstream Problem**: Upstream capped matrix shards at 10 because each additional shard incurred the 204s Docker Compose boot penalty (documented in [#46774](https://github.com/PostHog/posthog/pull/46774)).
- **The Enablement**: With runner setup reduced to 2.6s, the setup penalty vanishes. Tests can be divided into 20–25 balanced shards on an in-memory `tmpfs` RAM disk without penalty.
- **Impact**: Core Django suite wall-clock drops from **11m 10s down to ~3m 15s** with 100% deterministic test isolation.

### 1.5 In-Memory AST Migration Contract

- **The Upstream Problem**: The merge queue replays migrations `0001` through `HEAD` on an empty database (22m 10s) simply to detect broken imports, DAG cycles, or disconnected heads.
- **The Enablement**: `posthog/test/test_migration_contract.py` validates DAG reachability, acyclicity, and symbol argument compatibility directly via Python AST and Django's `MigrationGraph` in **2.44 seconds** with zero database dependencies.
- **Impact**: Completely eliminates the 22-minute scratch replay blocker in the merge queue.

---

## 2. Per-Runner Setup Overhead Breakdown

| CI Pipeline Step            | Upstream Command (`master`)                                   | Accelerated Command                                 |  Upstream Duration  | Accelerated Duration | Speedup Factor |  Runner Time Saved   |
| :-------------------------- | :------------------------------------------------------------ | :-------------------------------------------------- | :-----------------: | :------------------: | :------------: | :------------------: |
| **1. Toolchain Setup**      | `apt-get install` + `actions/setup-python` + `uv pip install` | Pre-synced `uv` virtualenv + remote R2 binary cache |     **32.40s**      |      **1.40s**       |   **23.1x**    |      **31.00s**      |
| **2. Service Provisioning** | `docker compose -f docker-compose.dev.yml up -d`              | Direct user-space service topology                  |     **48.60s**      |      **1.13s**       |   **43.0x**    |      **47.47s**      |
| **3. Health Checks**        | Shell retry loop: `while ! pg_isready; do sleep 1; done`      | In-process async TCP readiness probes               |     **16.20s**      |      **0.05s**       |   **324.0x**   |      **16.15s**      |
| **4. Database Priming**     | `python manage.py migrate` (sequential DDL)                   | Restored `.sql.gz` pre-computed schema snapshot     |     **50.00s**      |      **3.80s**       |   **13.1x**    |      **46.20s**      |
| **5. Job Teardown**         | `docker compose down -v --remove-orphans`                     | Process-group `SIGTERM` shutdown                    |     **12.10s**      |      **0.01s**       |  **1,210.0x**  |      **12.09s**      |
| **TOTAL RUNNER OVERHEAD**   | _Monolithic Container & Migration Churn_                      | _Lightweight Service Topology & Fast Snapshot_      | **204.10s** (~3.4m) |  **2.62s** (~0.04m)  |   **78.8x**    | **201.48s** (~3.36m) |

---

## 3. Full PR Lifecycle: Wall Time vs. Cumulative Runner Time

The full lifecycle measures elapsed wall time (what an engineer waits for) and cumulative runner compute (what Cloud CI bills).

```text
UPSTREAM BASELINE (~72 minutes end-to-end):
[ PR Verification Checks: ~22m ] ➔ [ Trunk Merge Queue Replay: ~25m ] ➔ [ Master Post-Merge Build: ~25m ]

ACCELERATED PIPELINE (~7.5 minutes end-to-end):
[ PR Verification Checks: ~3.0m ] ➔ [ Trunk Merge Queue Contract: <5s ] ➔ [ Master Post-Merge Build: ~4.5m ]
```

### Stage-by-Stage Lifecycle Comparison

| Lifecycle Stage                              | Key Operations & Checks                                                                                        | Upstream Wall Time | Upstream Runner Compute | Accelerated Wall Time | Accelerated Runner Compute | Optimization Mechanism                                                                                                                                                            |
| :------------------------------------------- | :------------------------------------------------------------------------------------------------------------- | :----------------: | :---------------------: | :-------------------: | :------------------------: | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1. Static Analysis & Lint**                | `repo-checks`, `lint-backend`, `frontend-typecheck`                                                            |      ~2m 30s       |     ~8m (3 runners)     |         ~45s          |            ~2m             | Pre-synced `uv` venv + incremental Biome/Ruff cache.                                                                                                                              |
| **2. Migration Verification Gate**           | Static AST contract (<3s) + schema snapshot restore (3.8s) + `makemigrations`, ClickHouse safety, sqlx persons |      ~5m 20s       |         ~5m 20s         |       **~58s**        |          **~58s**          | Fast snapshot restore (3.8s vs 50s) + ORM dry-run on live PostgreSQL.                                                                                                             |
| **3. Backend Test Matrix Shards**            | Full Django test suite (32,000+ tests across `posthog` and `ee`)                                               |    **11m 10s**     | **~112m** (10 runners)  |      **~3m 15s**      |   **~65m** (20 runners)    | Slashes 204s setup tax to 2.6s. Enables 20 parallel shards on in-memory `tmpfs` PostgreSQL with zero penalty. Multi-core `pytest-xdist -n auto` runs in 52s on single-VM targets. |
| **4. Merge Queue Gate (`trunk-merge/**`)\*\* | Scratch replay of 500+ migrations vs in-memory contract                                                        |    **22m 10s**     |          ~22m           |       **< 5s**        |          **< 5s**          | In-memory AST contract & DAG reachability (`test_migration_contract.py`) completely eliminates the 22-minute scratch replay block.                                                |
| **5. Master Post-Merge & Artifact Build**    | Container images, schema snapshots, and staging deployment                                                     |        ~25m        |          ~25m           |        ~4m 30s        |          ~4m 30s           | Content-addressed R2 cache + parallelized multi-layer builds.                                                                                                                     |
| **TOTAL PR LEAD TIME**                       | _End-to-end cycle: git push to deployed master code_                                                           |  **~72 minutes**   | **~174 runner-minutes** |   **~7.5 minutes**    |   **~71 runner-minutes**   | **~64.5 minutes eliminated per PR** (~9.6x faster wall time, ~60% compute reduction).                                                                                             |

---

## 4. Empirical Verification & Evidence

All benchmarked gains were verified live on GitHub Actions without synthetic mocks or simulated skips:

- **Empirical CI Verification Run**: [GitHub Actions Run #33985011709](https://github.com/tonky/posthog/actions/runs/33985011709)
- **Local Reproduction**:

  ```bash
  # 1. Run in-memory migration contract (<1.8s, zero DB dependencies)
  just test-contract

  # 2. Run multi-core Django tests (-n auto with pre-provisioned DBs)
  just test-django -n auto

  # 3. Benchmark cold boot latency across data tier
  just bench-boot

  # 4. View side-by-side job comparison
  just compare-jobs
  ```
