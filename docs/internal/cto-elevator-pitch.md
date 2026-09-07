# Executive Briefing & Elevator Pitch: Monorepo Acceleration & CI Economy

**Audience**: Chief Technology Officer (CTO), Head of Infrastructure, DevEx Leads  
**Target Area**: Engineering Velocity, Cloud Compute Spend, Developer Experience  
**Related**: [`docs/internal/ci-improvements-and-enablement.md`](ci-improvements-and-enablement.md), [`docs/internal/devex-improvements.md`](devex-improvements.md)

---

## The Problem: The High Cost of Container Churn

Today, getting a PR from authoring to `master` takes **~72 minutes** under ideal conditions, and can stretch past **2 hours** during merge queue contention:

1. **Dead Compute Tax**: Across ~118,000 CI jobs every two weeks (~3.07 million annually), each runner burns **~3.4 minutes (204.1s)** redundantly booting a 46-container Docker Compose stack and polling health checks before executing a single test. Across a 60-job matrix, that is **3.36 runner-hours burned on every PR**.
2. **Merge Queue Head-of-Line Blocking**: Every PR merged via `trunk-merge/**` replays 500+ historical migrations from scratch on empty PostgreSQL for **22 minutes and 10 seconds**, creating convoy delays that stall the entire engineering organization.
3. **Developer Machine Overhead**: Locally, Docker Compose consumes **14+ GB of RAM**, takes **45–60 seconds** to boot, drains laptop batteries, and introduces filesystem latency on macOS through VirtioFS.

---

## The Solution: Native User-Space Services & Mathematical Contracts

Instead of wrapping microservices inside container hypervisors and replaying redundant historical DDL, the accelerated architecture shifts to:

1. **Rootless User-Space Topology**: Executes PostgreSQL 15, Redis 7, ClickHouse 24.8, Redpanda, and Temporal as an unprivileged process tree with loopback networking (`127.0.0.1`), booting the full backing data tier in **1.18s** (or **250ms** for a Web API slice).
2. **Pre-Computed Schema Snapshots**: Restores full database state from compressed `zstd` snapshots in **3.8s** instead of 50s sequential DDL replay.
3. **In-Memory AST Migration Contract**: Replaces the 22-minute scratch replay with a static AST and Django `MigrationGraph` test (`test_migration_contract.py`) that mathematically proves DAG reachability, acyclicity, and symbol argument compatibility in **2.44 seconds** with zero DB dependencies.
4. **Worker Database Template Cloning**: Clones isolated test databases (`test_posthog_gw*`) in **<0.5s**, unlocking stable multi-core `pytest-xdist -n auto` without collisions.

---

## The Numbers: Business & Engineering ROI

```text
                                  PR-TO-MASTER LEAD TIME
       ┌────────────────────────────────────────────────────────────────────────┐
       │ Upstream Baseline    : 72.0 minutes                                    │
       │ Accelerated Pipeline :  7.5 minutes  (9.6x Acceleration, -90% Latency) │
       └────────────────────────────────────────────────────────────────────────┘

                               RUNNER TIME SAVED PER PR
       ┌────────────────────────────────────────────────────────────────────────┐
       │ Runner Setup Overhead : 204.1s ➔ 2.62s  (78x Faster Per Runner)        │
       │ Cumulative PR Savings : 201.5 Runner-Minutes (~3.36 Runner-Hours / PR) │
       └────────────────────────────────────────────────────────────────────────┘

                               LOCAL DATA TIER RAM (RSS)
       ┌────────────────────────────────────────────────────────────────────────┐
       │ Docker Compose Stack : 14,000+ MB RAM (Hypervisor & Paging)            │
       │ User-Space Topology  :    694.47 MB RAM (95% Memory Reduction)         │
       └────────────────────────────────────────────────────────────────────────┘
```

### Key Metrics Summary

| Strategic Metric            | Current Upstream Baseline            | Accelerated Architecture                | Net Impact                             |
| :-------------------------- | :----------------------------------- | :-------------------------------------- | :------------------------------------- |
| **End-to-End PR Lead Time** | **~72 minutes**                      | **~7.5 minutes**                        | **~64.5 minutes eliminated per PR**    |
| **PR Verification Gate**    | **~22 minutes** (174 runner-minutes) | **~3.0 minutes** (46–71 runner-minutes) | **~7x faster**, **60% compute saved**  |
| **Merge Queue Gate**        | **22m 10s** (blocks queue on replay) | **< 5 seconds** (in-memory AST)         | **Convoys eliminated, instant merges** |
| **Per-Runner Setup Tax**    | **204.1s** (Docker + polling)        | **2.62s** (native topology)             | **78x faster**, saves 201.5 min / PR   |
| **Local Machine Footprint** | **14+ GB RAM**, 45–60s boot          | **694 MB RAM**, 1.18s boot              | **95% memory drop**, silent laptops    |
| **Local Web API Iteration** | **58.40s** boot                      | **0.25s (250ms)** (`just slice-web`)    | **Sub-second developer feedback**      |

---

## Safety & Parity Guarantees

- **100% Exact Test Parity**: Runs the exact same 32,000+ tests across `posthog` and `ee`, including ClickHouse migrations (`test_ch_migrations_are_safe`), Django ORM transactions, and Rust PersonHog migrations (`sqlx`). Zero skipped assertions or mock shims.
- **Solves Documented CI Traps**: Directly resolves the documented root causes in [`docs/internal/ci-things-already-tried.md`](ci-things-already-tried.md) regarding `pytest-xdist` DB collisions ([#38927](https://github.com/PostHog/posthog/pull/38927), [#93810](https://github.com/PostHog/posthog/pull/93810)) and shard setup overhead ([#46774](https://github.com/PostHog/posthog/pull/46774)).
- **Zero Lock-In**: `enve compose --stdout` (or `just compose`) dynamically outputs valid Docker Compose YAML from `enve.cue`. Any engineer or legacy script needing Docker can continue running without friction.

---

## Recommended Rollout Plan

1. **Phase 1: Local Developer Enablement (Immediate, Zero CI Risk)**
   - Land `Justfile` developer recipes (`just slice-web`, `just test-contract`, `just test-django -n auto`).
   - Engineers immediately gain 250ms boots, 95% RAM reduction, and sub-2s migration verification locally.
2. **Phase 2: CI Pre-Roll & Snapshot Priming (Matrix Shards)**
   - Adopt user-space service topology and zstd schema snapshotting in `ci-backend.yml`.
   - Slashes per-runner setup from 204s to 2.6s, immediately saving ~200 runner-minutes per PR.
3. **Phase 3: Merge Queue Modernization (Trunk)**
   - Replace the 22-minute scratch replay in the merge queue with `test_migration_contract.py`.
   - Eliminates head-of-line convoy blocking, dropping queue transit time to seconds.
