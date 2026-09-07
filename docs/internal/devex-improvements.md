# Developer Experience (DevEx) Improvements: Local Acceleration & Resource Efficiency

**Status**: Active Architecture & Benchmark Specification  
**Target Area**: Local Development Environment, Laptop Battery & RAM Efficiency, Tooling Latency  
**Related**: [`docs/internal/ci-improvements-and-enablement.md`](ci-improvements-and-enablement.md), [`docs/internal/enve-local-dev-acceleration.md`](enve-local-dev-acceleration.md), [`Justfile`](../../Justfile)

---

## Executive Overview

Local development on the PostHog monorepo has traditionally carried high operational friction:

- **Massive RAM Footprint**: Running the standard 46-container Docker Compose stack (`docker-compose.dev.yml`) consumes **14+ GB of physical RAM**, forcing macOS and Linux laptops into continuous kernel memory swapping.
- **Sluggish Cold Starts**: Booting the full backing stack takes **45 to 60+ seconds**, followed by 30 seconds of health-check polling.
- **Thermal & Battery Drain**: Background container hypervisors and polling loops cause excessive CPU wakeups, thermal throttling, and rapid battery discharge.
- **Filesystem Latency**: Cross-boundary volume mounts on macOS (VirtioFS / gRPC-FUSE) introduce measurable I/O latency on hot-reload and local test execution.
- **Migration Friction**: Checking whether a local migration introduces DAG cycles or breaks historical imports previously required a **22-minute from-scratch database replay**.

By introducing **rootless user-space service topology**, **granular intent slices**, **instant CUE toolchain evaluation**, and **in-memory AST migration verification**, local development is transformed into a lightweight, sub-second experience.

---

## 1. Resource Footprint: Docker Compose vs. Lightweight Topology

```text
                           LOCAL DATA TIER MEMORY FOOTPRINT (RSS)
    ┌───────────────────────────────────────────────────────────────────────────┐
    │ Docker Compose (46 containers) : 14,000+ MB RAM (Hypervisor + Swapping)   │
    │ Lightweight Topology (5 core)  :    694.47 MB RAM (Native User Namespace) │
    └───────────────────────────────────────────────────────────────────────────┘
                                95% Physical Memory Reduction
```

| Metric                         | Docker Compose (`docker-compose.dev.yml`) | Lightweight Topology (`Justfile` / `enve`) | Measured Improvement                 |
| :----------------------------- | :---------------------------------------- | :----------------------------------------- | :----------------------------------- |
| **Physical RSS Memory**        | **14,000+ MB** (container hypervisor)     | **694.47 MB** (native process tree)        | **~95% memory reduction**            |
| **Cold Boot Latency**          | **45.0s – 60.0s** (+ 30s polling)         | **1.13s** (topological DAG startup)        | **~40x – 50x faster cold boot**      |
| **Filesystem I/O Overhead**    | High (VirtioFS VM translation layer)      | **Zero** (native host direct I/O)          | Instant file watch & test collection |
| **User Privileges Required**   | Docker root daemon / VM socket            | **Unprivileged user space** (rootless)     | Zero root / daemon dependencies      |
| **Migration DAG Verification** | 1,330s (22 min 10s fresh replay)          | **1.79s** (in-memory AST contract)         | **744x faster feedback**             |

---

## 2. Granular Intent Slices: Boot Only What You Touch

Instead of forcing developers to boot 46 containers regardless of the task, the architecture introduces **intent-based service slices**:

```text
=======================================================================
  📦 Declared Service Topology
=======================================================================
  - postgres   : postgres -D data/postgres/data -p 15432 (port: 15432)
  - redis      : redis-server --port 16379 --save '' --appendonly no (port: 16379)
  - clickhouse : clickhouse-server --config-file data/clickhouse/config.xml (port: 18123)
  - redpanda   : redpanda --redpanda-cfg data/redpanda/conf/redpanda.yaml (port: 19092)
  - temporal   : temporal server start-dev --ip 127.0.0.1 --port 7233 (port: 7233)
  - capture    : cargo run --manifest-path services/capture/Cargo.toml (port: 18000)
=======================================================================
```

| Developer Intent Slice | Command                | Services Started                                            | Startup Latency   | Idle Memory (RSS) | Typical Use Case                    |
| :--------------------- | :--------------------- | :---------------------------------------------------------- | :---------------- | :---------------- | :---------------------------------- |
| **Web API Slice**      | `just slice-web`       | PostgreSQL 15 + Redis 7                                     | **0.25s (250ms)** | **135 MB**        | Django REST API, frontend, settings |
| **Ingestion Slice**    | `just slice-ingestion` | Redis + Redpanda + ClickHouse                               | **0.60s (600ms)** | **442 MB**        | Ingestion pipeline, events, Capture |
| **Full Monorepo Tier** | `just slice-full`      | All 6 services (PG, CH, Redis, Redpanda, Temporal, Capture) | **1.18s**         | **694 MB**        | Full end-to-end local testing       |
| **Compose Baseline**   | `docker compose up -d` | Monolithic container set                                    | **58.40s**        | **14,000+ MB**    | Legacy all-or-nothing baseline      |

Developers can start individual services on demand (`just up postgres`, `just up clickhouse`) and tear them down in under a second (`just down`).

---

## 3. Toolchain Performance: Flox vs. CUE Engine

The development toolchain configuration was evaluated to minimize shell startup latency and eliminate wrapper friction:

| Feature / Capability      | PostHog Flox Setup (`.flox`)         | CUE / User-Space Engine (`enve`)          |
| :------------------------ | :----------------------------------- | :---------------------------------------- |
| **Configuration Format**  | TOML + 158 KB `manifest.lock`        | Single `enve.cue` (typed, schema-checked) |
| **Activation Engine**     | Flox daemon + FloxHub catalog        | Pure-Rust CUE AST (zero daemons)          |
| **Activation Hook**       | 543-line bash script (`on-activate`) | **Zero bash scripts needed**              |
| **Evaluation Latency**    | **3 to 8 seconds**                   | **< 50 microseconds**                     |
| **Microservice Topology** | Not supported (requires Docker)      | **Native** (unprivileged process DAG)     |
| **Compose Export**        | Not supported                        | **Native** (`enve compose --stdout`)      |

Running `enve develop` launches an interactive hermetic subshell in under a millisecond with all pinned tools (`python313`, `uv`, `rust`, `cargo`, `clickhouse`, `postgres`, `redis`, `redpanda`, `temporal`) available without polluting the developer's global environment.

---

## 4. Instant In-Memory Migration Contract (`just test-contract`)

### The Problem

Historically, validating that local schema changes did not introduce circular dependencies or break historical imports required dropping and rebuilding a local database from migration `0001` through `HEAD` (2,691+ migration files across 80+ apps), consuming **22 minutes and 10 seconds**.

### The Mathematical Solution

`posthog/test/test_migration_contract.py` eliminates the database dependency entirely:

1. **Static AST/Regex Extraction**: Parses `dependencies`, `replaces`, and `run_before` without importing dynamic modules, completing in ~0.1s.
2. **Authentic Django Graph Validation**: Feeds stubs into Django's native `MigrationGraph` to verify `validate_consistency()`, `ensure_not_cyclic()`, and `forwards_plan(leaf)` reachability.
3. **AST Parameter & Signature Contract**: Scans historical migrations to prove all referenced functions and constants still exist and accept their historically required arguments.
4. **Phase 1 App Bootstrap**: Bypasses heavy signal handlers and model population, cutting initialization to 0.51s.

```bash
$ just test-contract
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

---

## 5. Conflict-Free Local Multi-Core Testing (`pytest-xdist`)

Running tests locally across all CPU cores previously failed with database collisions. The developer recipe `just test-django -n auto` solves this automatically:

- Checks if worker template databases exist; if missing, clones them from `test_posthog` via `CREATE DATABASE ... TEMPLATE` in **<0.5s**.
- Maps each worker (`gw0`, `gw1`, etc.) to its isolated database slice.
- Developers can execute targeted suites locally in seconds:

  ```bash
  # Run Django settings debug guard with multi-core auto-detection
  just test-django

  # Run HogVM bytecode interpreter suite across 4 cores
  just test-hogvm -n 4

  # Run full repository architectural invariants in parallel
  just test-invariants -n 2

  # Target any specific test file or directory
  just test-full-xdist posthog/api/test/test_feature_flag.py -n 4
  ```

---

## 6. Backward Compatibility & Zero Lock-In

The architecture requires no breaking changes to developer habits:

- **Dynamic Compose Export**: If a third-party tool or legacy script requires Docker Compose, running `enve compose --stdout` (or `just compose`) generates valid `compose.yaml` on the fly from `enve.cue`.
- **Side-by-Side Coexistence**: Developers who prefer Docker Compose can continue using `./bin/start` or `hogli start` without conflicts.
- **Port Isolation**: Services run on dedicated non-colliding ports (PostgreSQL: 15432, Redis: 16379, ClickHouse: 18123/19000), allowing parallel operation alongside host services.
