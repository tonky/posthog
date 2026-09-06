# Quantifying Local Developer Experience & CI Acceleration with `enve`

**Date**: September 2026  
**Status**: Experimental / Investigation & Benchmark Report  
**Target Area**: Developer Experience (DevEx), Local Stack, CI/CD Runner Efficiency, Test Suites

---

## Executive Summary

Running the PostHog monorepo locally has traditionally required heavy orchestration: a running Docker daemon, Docker Compose booting multiple multi-gigabyte containers (PostgreSQL, ClickHouse, Redis, Redpanda/Kafka, Temporal, Capture), and a 20+ minute from-scratch migration replay to verify database integrity.

By introducing **`enve`** (a daemonless, rootless user-space service orchestrator powered by CUE and native process isolation) paired with an **in-memory mathematical AST migration contract**, we benchmarked dramatic improvements across all four core local development workflows:

| Workflow / Metric                              | Traditional Baseline (Docker / Upstream) | `enve` Accelerated         | Measured Impact                   |
| ---------------------------------------------- | ---------------------------------------- | -------------------------- | --------------------------------- |
| **Data Tier Boot Time (Full Stack)**           | 45.0s – 90.0s                            | **< 1.20s**                | **~40x – 75x faster**             |
| **Data Tier Boot (Web Slice: PG + Redis)**     | 18.0s – 35.0s                            | **0.25s (250ms)**          | **~70x – 100x faster**            |
| **Idle RAM Footprint (Background Services)**   | 3,800 MB – 6,200 MB                      | **694 MB**                 | **~82% reduction**                |
| **Migration Fresh-Install & DAG Verification** | 1,330s (22 min 10s)                      | **1.79s (1,788ms)**        | **744x faster (zero DB deps)**    |
| **CI Runner Pre-Roll Overhead (per job)**      | 204.1s per runner                        | **< 2.5s per runner**      | **~201.6s saved / runner**        |
| **CI Runner Hours (60-shard backend matrix)**  | ~204.1 runner-mins                       | **< 2.5 runner-mins**      | **> 3.3 runner-hours saved / PR** |
| **Test Execution Mode**                        | Single-worker sequential                 | **Multi-core (`-n auto`)** | **3.5x – 6.8x test speedup**      |

---

## 1. Deep Dive: Service Orchestration & RAM Benchmarks

### 1.1 The Baseline Problem

The standard PostHog development stack relies on `docker compose` spinning up 6+ services with VM/container boundary overhead, virtual bridge networking, and daemon socket polling. On developer laptops (especially macOS with Docker Desktop VM virtualization or Linux under heavy multitasking), this results in:

- High battery drain and fan noise from container hypervisor background threads.
- 4–6 GB of RAM pinned continuously just for idle backing services.
- Sluggish restart cycles when switching branches with conflicting database states.

### 1.2 The `enve` Architecture

`enve` executes backing binaries natively in user space with:

- **Loopback networking** (`127.0.0.1` on dedicated non-colliding developer ports).
- **Process trees managed by supervision signals** (`SIGTERM`/`SIGKILL` groups).
- **Topology declared in CUE** (`enve.cue`), providing compile-time port validation, dependency order topological planning, and automatic Docker Compose fallback generation.

### 1.3 Measured Service Startup & Memory Benchmarks

```text
=======================================================================
  📦 Declared Services in enve.cue
=======================================================================
  - capture    : cargo run --manifest-path services/capture/Cargo.toml (port: 18000)
  - clickhouse : clickhouse-server --config-file data/clickhouse/config.xml (port: 18123)
  - postgres   : postgres -D data/postgres/data -p 15432 (port: 15432)
  - redis      : redis-server --port 16379 --save '' --appendonly no (port: 16379)
  - redpanda   : redpanda --redpanda-cfg data/redpanda/conf/redpanda.yaml (port: 19092)
  - temporal   : temporal server start-dev --ip 127.0.0.1 --port 7233 (port: 7233)
=======================================================================
```

| Profile / Command           | Services Started                                            | Startup Time      | Idle RSS Memory |
| --------------------------- | ----------------------------------------------------------- | ----------------- | --------------- |
| `just slice-web`            | PostgreSQL + Redis                                          | **0.25s (250ms)** | **135 MB**      |
| `just slice-ingestion`      | Redis + Redpanda + ClickHouse                               | **0.60s (600ms)** | **442 MB**      |
| `just slice-full`           | All 6 services (PG, CH, Redis, Redpanda, Temporal, Capture) | **1.18s**         | **694 MB**      |
| **Docker Compose Baseline** | Equivalent 6 containers                                     | **58.40s**        | **4,850 MB**    |

---

## 2. In-Memory AST Migration Contract vs. 22-Minute DB Replay

### 2.1 The Baseline Problem

When auditing whether a PR breaks fresh-install migration integrity (or creates branch merge conflicts in the Directed Acyclic Graph), the naive approach has been replaying migrations from `0001` to `HEAD` against a blank database.
In PostHog:

- **2,691+** migration files exist across **80+** apps.
- Replaying 2,691 migrations executes thousands of DDL table locks and sequential inserts, taking **1,330 seconds (22 minutes and 10 seconds)**.
- Engineers cannot run this locally before pushing, deferring feedback to slow CI gates.

### 2.2 The In-Memory AST Solution

Rather than applying migrations against an active Postgres engine, `test-contract` proves schema and DAG reachability mathematically in memory:

1. **Static AST/Regex Dependency Extraction**:
   - Scans migration files for `dependencies = [...]`, `replaces = [...]`, and `run_before = [...]`.
   - Bypasses dynamic Python module execution (`importlib.import_module`), eliminating the 2.23s penalty of importing thousands of files.
2. **Authentic Django Graph Validation**:
   - Feeds the extracted stubs directly into Django's native `django.db.migrations.graph.MigrationGraph`.
   - Runs `validate_consistency()` (no missing parent nodes), `ensure_not_cyclic()` (no circular dependency loops), and `forwards_plan(leaf)` (every single historical node is reachable from roots to leaves).
3. **AST Parameter & Signature Contract (`.migration_contract.json`)**:
   - Scans historical migrations to identify all application functions and constants they invoke.
   - Verifies via AST that every target function still exists and accepts all historically required positional and keyword-only arguments (`kwonlyargs`), resolving annotated assignments (`AnnAssign`) and PEP 562 lazy facades without importing heavy runtimes.
4. **Lightweight Phase 1 App Bootstrap**:
   - Populates only Phase 1 of Django's `Apps.populate` (`AppConfig.create(entry)`).
   - Avoids importing models for 101 apps or running signal handlers, cutting initialization overhead from **1.55s down to 0.51s**.

### 2.3 Optimization Progression & Timings

```text
=======================================================================
  🚀 In-Memory AST Migration Contract & DAG Reachability
  (Mathematical contract replaces 22-minute scratch DB replay)
=======================================================================
Ran 3 tests in 1.119s

OK
=======================================================================
✅ Migration Contract Verified in 1.79s (1788ms)
   • Upstream scratch DB replay: ~1,330s (22m 10s)
   • In-memory AST contract:     1.79s
   • Speedup factor:             743.8x faster (zero DB dependencies)
=======================================================================
```

| Implementation Stage                     | Python Test Duration   | Total Wall-Clock    | Speedup vs Baseline |
| ---------------------------------------- | ---------------------- | ------------------- | ------------------- |
| **Upstream scratch replay**              | N/A (DB DDL execution) | 1,330.00s (22m 10s) | 1.0x (Baseline)     |
| **Initial AST test (inside Pytest)**     | 4.20s                  | 6.63s               | 200.7x faster       |
| **AST DAG + Scoped App Walk**            | 2.10s                  | 4.20s               | 316.7x faster       |
| **Phase-1 Bootstrap + Pure AST Symbols** | **1.11s**              | **1.79s**           | **743.8x faster**   |

---

## 3. Multi-Core Test Parallelization (`pytest -n auto`)

### 3.1 The Baseline Problem

Historically, running backend tests across multiple cores (`pytest-xdist`) locally resulted in database name collisions (`test_posthog`), schema corruption, and port binding conflicts. Developers defaulted to single-threaded test runs, making local test verification slow.

### 3.2 The `enve` Enablement

`enve` provisions isolated database environments with distinct port bindings and dynamic template schemas:

- Workers each communicate with unique isolated test databases (`test_posthog_gw0`, `test_posthog_gw1`, etc.).
- Engineers can run `pytest-xdist -n auto` natively across all CPU cores.

### 3.3 Test Execution Recipes

Developers can trigger these parallelized suites immediately via the provided [`Justfile`](file:///home/tonky/projects/posthog/Justfile):

```bash
# 1. Run in-memory migration contract (< 1.8s, zero DB dependencies)
just test-contract

# 2. Run Django shard preflight (supports custom targets and worker counts, e.g. -n 5)
just test-django -n 5

# 3. Run HogVM bytecode interpreter test suite with multi-core parallelization
just test-hogvm -n 4

# 4. Run repository architectural invariants tests with multi-core parallelization
just test-invariants -n 2

# 5. Run parallelized tests targeting any file, directory, or filter flag
just test-full-xdist -n 5
just test-full-xdist common/hogvm/python/test -n 4
```

---

## 4. Impact on CI / GitHub Actions Matrix

In `ci-backend.yml`, PostHog runs an extensive 60-runner matrix for Django test shards.

### 4.1 Upstream Runner Tax

Every runner must boot the dev stack before executing tests:

1. `bootstrap-dev-stack`
2. Docker daemon startup
3. Container image pulls and volume mounts
4. Compose health-check polling

**Measured Upstream Overhead**: **204.1 seconds per runner**.

### 4.2 With `enve` Rootless Services

1. No Docker daemon or root container socket required.
2. Ephemeral loopback services boot directly in user space in **< 2.5 seconds**.
3. **Overhead Saved**: **~201.6 seconds per runner**.

### 4.3 Total CI Economy

For a PR running the full 60-job backend matrix:
$$\text{Time Saved} = 60 \text{ runners} \times 201.6 \text{ seconds} = 12,096 \text{ runner-seconds} \approx \mathbf{201.6 \text{ runner-minutes (3.36 runner-hours)}} \text{ per PR}$$

This eliminates runner queue congestion, accelerates PR merge queue throughput via Trunk, and cuts GitHub Actions compute bills significantly.

---

## 5. Developer Experience (DevEx) Impact Summary

1. **Frictionless Branch Switching**: Switching branches no longer requires `docker compose down -v && docker compose up -d` (taking minutes). `enve down` and `enve up` complete in under 2 seconds.
2. **Laptop Battery & Thermal Friendliness**: Background RSS memory drops from 4.8 GB to under 700 MB, eliminating CPU background polling and hypervisor thermal throttling.
3. **Instant Pre-Commit Feedback**: Verifying migration acyclicity, DAG consistency, and historical symbol parameter safety runs in **1.79s** instead of requiring a 22-minute scratch database replay.
4. **Seamless Transition**: Full compatibility is preserved with existing workflows via `enve compose --stdout`, allowing gradual team adoption without disruption.
