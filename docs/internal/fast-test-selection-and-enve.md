# PostHog DeveX Strategy: Fast Local Verification & Shift-Left CI

## Executive Summary

Testing in the PostHog monorepo faces a severe latency and cost mismatch:

- **Typical PR changes** are localized (e.g. adding a permission guard, tweaking a Temporal activity, or updating a warehouse data source).
- **Upstream GitHub Actions CI** runs **14 to 25 minutes** across 25 parallel matrix runners burning **100–200 runner-minutes** per run because of unsealed product boundaries, Docker container provisioning overhead (80–100s per runner), and coarse fallback test matrices.
- **Local Developer Testing** with Docker Compose consumes **4,000–8,000 MB RSS**, takes 60–90 seconds to boot, and requires manual guesswork to decide which tests to run.

By pairing **Snob AST Impact Analysis** (`tools/snob_backend_test_selection_shadow.py`) with **Rootless In-Process Microservices** (`enve`), we reduce developer test feedback loops from **15–25 minutes down to 10–35 seconds** locally, using **<450 MB RSS total** for all 6 core services (PostgreSQL, ClickHouse, Redis, Kafka, SeaweedFS S3, Temporal).

---

## 1. Problem Statement & Root Cause Analysis

### A. The Monorepo Isolation Problem

PostHog contains ~80 modular product apps under `products/`. However:

1. **Unsealed Boundaries**: Over 60 products are unsealed (`products/isolation_baseline.txt`), leaking imports across boundaries.
2. **Build-System Coarseness**: Tools like Turborepo (`turbo.json`) and Tach operate at the package/directory layer. Any change in an unsealed product invalidates boundary guarantees, forcing CI to fall back to running broad cross-product suites.
3. **Django Framework Indirection**: Standard static dependency graphs only catch ~33% of test dependencies because Django uses dynamic routing (e.g. `client.get("/api/projects/@current/...")`), model signal handlers (`post_save`, `m2m_changed`), and custom database routers.

### B. The Container & VM Setup Tax

Upstream CI jobs spend **80–100 seconds** per runner just waiting for Docker Compose:

- Pulling container images and running `wait-for-docker` (25–30s)
- Restoring prewarmed database template dumps (35–45s)
- Booting Temporal servers (15–20s)
  For a test suite that only takes 15 seconds to execute, **85% of the CI runner's time is dead container setup tax**.

---

## 2. Our Architecture: Snob AST + Rootless Enve Services

```mermaid
graph TD
    A[Git Diff / PR Changes] --> B[Snob AST Selector]
    B -->|1. Direct Python Imports| C[Impacted Test Graph]
    B -->|2. AST URL Route Matching| C
    B -->|3. Django Signal/App Expansion| C

    C --> D[Local Rootless enve Runtime]

    subgraph Enve Services [In-Process Rootless Services (~450 MB RSS total)]
        S1[(PostgreSQL: 15432)]
        S2[(ClickHouse: 8123)]
        S3[(Redis: 16379)]
        S4[(Tansu Kafka: 19092)]
        S5[(SeaweedFS S3: 19000)]
        S6[Temporal: 7233]
    end

    D --> Enve Services
    D --> E[Fast Feedback in 10s - 35s]
```

### Core Innovations:

1. **Deterministic Test Blast Radius (Snob AST Engine)**:
   - Evaluates `git diff` against base branch (`origin/master`).
   - Traces Python import dependencies via `pytest-snob`.
   - Analyzes test ASTs for Django test client requests (`Client.get()`, `APIClient.post()`) and resolves string API paths back to their Django viewsets.
   - Enforces product isolation bounds (`same_app` fallback).
   - Finishes selection in **~1.5 seconds**.

2. **Rootless Microservices via Enve (Zero-Docker)**:
   - **PostgreSQL**: Runs natively on loopback port `15432` with memory-optimized parameters (`fsync=off`, `synchronous_commit=off`).
   - **ClickHouse**: Native user-space binary on port `8123` with ephemeral storage.
   - **Redis**: In-process on port `16379` (`save ''`, `appendonly no`).
   - **Kafka (Tansu)**: Pure Rust in-memory Kafka implementation on port `19092` (15 MB RSS vs 1.5 GB JVM Kafka).
   - **SeaweedFS S3**: High-performance S3 endpoint on port `19000` on tmpfs.
   - **Temporal**: Headless dev-server on port `7233` with SQLite backing.
   - **Combined Footprint**: Boots in **2.86s total** with **~450 MB total RSS** (vs 4–8 GB Docker).

---

## 3. Real-World PR Benchmarks & Case Studies

We selected 3 typical, recent merged PRs across different feature areas:

| PR ID      | Feature / Component                                                                             | Upstream GitHub Actions CI                           | Local Docker Compose (Est.) | Snob + Enve Local Run            | Speedup vs CI |
| :--------- | :---------------------------------------------------------------------------------------------- | :--------------------------------------------------- | :-------------------------- | :------------------------------- | :-----------: |
| **#98893** | **Signals REST API Guard**<br/>`products/signals/backend/scout_harness/views.py`                | **23m 15s**<br/>(25 matrix runners, ~200 runner-min) | ~8–12 min                   | **34.5s**<br/>(350 tests passed) |   **~40x**    |
| **#99634** | **Business Knowledge Temporal Activity**<br/>`products/business_knowledge/backend/temporal/...` | **14m 45s**<br/>(~120 runner-min)                    | ~5–7 min                    | **20.4s**<br/>(16 tests passed)  |   **~43x**    |
| **#99520** | **AppsFlyer Warehouse Source**<br/>`products/warehouse_sources/backend/temporal/...`            | **13m 50s**<br/>(~110 runner-min)                    | ~4–6 min                    | **10.6s**<br/>(15 tests passed)  |   **~78x**    |

### Resource Comparison

- **Memory Footprint**: Upstream Docker consumes **4 GB to 8 GB**. Enve consumes **~450 MB** total across all 6 services.
- **Service Ready Time**: Docker takes **45–90s**. Enve services are ready in **2.8s**.
- **CPU & Battery (Laptops)**: Negligible idle load vs continuous Docker VM daemon heat and fan noise.

---

## 4. Developer Workflows & Commands

We have exposed this architecture directly through the repository root [`Justfile`](file:///Users/tonky/projects/posthog/Justfile) and [`showcase/Justfile`](file:///Users/tonky/projects/posthog/showcase/Justfile):

### Daily Developer Workflow

```bash
# 1. Start rootless background microservices (if not already running)
just services-up

# 2. Check service status and memory footprint
just services-status

# 3. List tests affected by your current branch diff (without executing)
just list-affected origin/master

# 4. Run ONLY affected backend tests against your git diff
just test-affected origin/master

# 5. Run ONLY affected frontend Jest tests against your git diff
just test-affected-frontend origin/master

# 6. Stop services when done
just services-down
```

### Reproducible PR Verification Demonstrations

To verify the speedup on real PR diffs:

```bash
# Demo 1: PR #98893 (REST API Team Guard - 350 backend tests in ~34s vs 23m CI)
just demo-pr-signals

# Demo 2: PR #99634 (Temporal Activity & Schemas - 16 backend tests in ~20s vs 14m CI)
just demo-pr-temporal

# Demo 3: PR #99520 (Warehouse Source - 15 backend tests in ~10s vs 13m CI)
just demo-pr-warehouse

# Demo 4: PR #99503 (Frontend Metrics - 3 Jest tests in ~10s vs 12m CI)
just demo-pr-frontend
```

Each demo automatically reverts the working copy, applies the saved diff, runs the tests in `enve`, and prints a comparative scorecard.

---

## 5. Strategic Roadmap & Next Steps

### Short-Term (Immediate DeveX Gains)

- **Local Adoption**: Developers and AI coding agents can use `just test-affected` before pushing, catching regressions in seconds instead of waiting for GitHub notifications.
- **Tighter Temporal Heuristics**: Refine `snob_backend_test_selection_shadow.py`'s Temporal heuristic from matching any path with `"temporal"` to scoping by product directory (`products/<product>/backend/temporal`), avoiding unnecessary whole-repo Temporal test runs.

### Medium-Term (CI Pipeline Integration)

- **Enve Container Action in CI**: Replace Docker Compose with in-process `enve` service execution on GitHub Actions runners, saving ~36.7 runner-minutes per PR.
- **Dynamic Coverage Inverted Index (Gen 3 TIA)**:
  Generate an inverted test-to-line coverage index in CI merge queue runs (via `pytest-testmon` / coverage mapping). This eliminates static AST guessing and replaces fallback `FULL_RUN_PATTERNS` with exact line-level test targeting.
