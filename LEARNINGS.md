# PostHog Engineering Learnings & Discoveries

This document captures architectural discoveries, testing subtleties, scoping mechanics, and environment patterns learned while developing and testing the PostHog platform.

---

## 1. Test Execution & CI Bottlenecks

### The CI Matrix vs. Local Execution Gap

- **CI Characteristics**:
  - GitHub Actions runs full backend matrices across 25 parallel runners (sharded across tests, migration checks, flake detection).
  - Frontend Jest test runs are sharded into 4 concurrent runners.
  - Typical PR turnaround: **15 to 30 minutes** wall-clock time, consuming substantial GitHub runner minutes.
- **Root Cause**:
  - CI runs the world on every push because historical static scoping was either unreliable or absent.
  - In practice, 80%+ of pull requests modify tightly bounded product verticals (e.g. `products/business_knowledge/`, `products/data_warehouse/`, or single frontend logics).
- **The Solution**:
  - Intelligent AST-based impact analysis (`snob_lib`) and Jest reverse-graph resolution (`jest --findRelatedTests`).
  - Running scoped tests on local tmpfs microservices takes **10 to 35 seconds** — offering 98%+ time savings and 100% parity with the relevant CI shards.

---

## 2. Test Scoping Mechanics

### Backend Test Scoping (`snob_lib` & AST Walking)

- Rather than running arbitrary directories, `snob_lib` parses the Python Abstract Syntax Tree (AST) to compute the reverse dependency graph across 5,000+ files.
- **Provenance & Fan-out**:
  - When PRs introduce or modify library code (e.g., `constants.py`, `schemas.py`, `analyze.py`), `snob_lib` traces which test modules directly or transitively import those files.
  - If a file is only imported by a single test module (e.g. `test_learning_analyzer.py`), only that single suite is executed.
  - Showing the exact provenance (which test was triggered by which changed file) builds developer confidence and verifies why unaffected tests were safely omitted.

### Frontend Test Scoping (`jest --findRelatedTests`)

- Jest includes built-in dependency resolution via `--findRelatedTests`.
- **The Barrel File Trap**:
  - PostHog frontend contains top-level barrel and registry files (e.g., `frontend/src/scenes/urls.ts`, `frontend/src/initKea.ts`).
  - If these files are touched or naively resolved, Jest triggers virtually every test in the repository.
  - **Mitigation**: Filter out root scenes/urls barrel files during related-test discovery unless specifically verifying routing/navigation logic.

### Why Not Sub-componentize via Turborepo / Tach?

- Tach operates on Python AST boundaries and does not enforce JavaScript/TypeScript module boundaries.
- The PostHog frontend is currently structured as a cohesive Vite + Kea single-page application.
- Attempting to split `frontend/src/` into 30+ npm packages introduces immense tooling overhead (monorepo build step latency, symlink issues, shared Kea logic bindings).
- `jest --findRelatedTests` provides instant scoping without requiring artificial package boundaries.

---

## 3. Microservice Environment Traps & Quirks

### Universal Hermeticity: `enve` for All Binaries, Dependencies, & Services

- **Hermetic Runtimes & Dependencies**:
  - Rather than relying on disparate host package managers, non-deterministic nvm/pyenv/rustup versions, or global paths, `enve` provides a fully sealed hermetic developer environment.
  - All compilers (Python, Node.js, Go, Rust), developer tools (`just`, `watchexec`, `ripgrep`, `jq`), and database packages are declared in `enve.cue` and pinned by cryptographic hashes in `enve.lock`.
- **Rootless Microservices vs. Heavy Docker Compose**:
  - Running Docker Compose locally consumes 4,000–8,000 MB RSS, takes 60–90 seconds to boot, and suffers severe volume translation overhead on macOS.
  - `enve.cue` runs real native binaries directly against tmpfs / RAM disks on localhost (<450 MB RSS total), providing sub-second restarts, instant test database wiping, and clean hermetic isolation.

### The Django Test Hostname Trap (`posthog/settings/data_stores.py`)

- In `posthog/settings/data_stores.py`, Django contains logic that defaults database hosts under `TEST = True`:
  - `PG_HOST` defaults to `"db"` (Docker container name) instead of `localhost`.
  - `CLICKHOUSE_HOST` defaults to `"clickhouse"` instead of `localhost`.
- **Fix / Rule**:
  - When invoking `pytest` locally outside Docker, you must explicitly supply:

    ```bash
    PGHOST=127.0.0.1 \
    PGPORT=15432 \
    CLICKHOUSE_HOST=127.0.0.1 \
    CLICKHOUSE_LOGS_HOST=127.0.0.1 \
    CLICKHOUSE_HTTP_PORT=8123 \
    pytest ...
    ```

  - Without these variables, pytest immediately hangs or errors attempting to resolve `"db"` or `"clickhouse"`.

### Rust Compilation Rule

- Compiling Rust services (`capture`, `personhog`, `hook-janitor`) locally or in rapid feedback loops takes several minutes and spikes system resources.
- **Rule**: Unless actively debugging the Rust ingestion binary, skip Rust compilation during PR evaluation and test scoping.

---

## 4. Git Hooks & Hermetic Tool Invocation

### Prioritizing `enve` in Git Hooks (`.husky/pre-commit`)

- Upstream hook scripts frequently check for `flox` or assume global npm/pnpm installations.
- When working in hermetic environments, hooks must check for `enve` and `enve.cue` first:

  ```bash
  if command -v enve > /dev/null 2>&1 && [ -f "enve.cue" ] && [ -z "$ENVE_ENV" ]; then
      exec enve run -- env POSTHOG_TELEMETRY_OPT_OUT=1 NODE_OPTIONS='--max-old-space-size=8192' corepack pnpm lint-staged
  ```

- **The Corepack Subtlety**: In sealed/Nix-backed Node environments, `corepack enable` cannot symlink to read-only store directories (`/nix/store/...`). Invoking `corepack pnpm <cmd>` directly bypasses the need for global write permissions and executes the exact pinned pnpm version hermetically.

---

## 5. Local Test Database Lifecycles & State Management

### Test Database Isolation on Port 15432

- Django creates dedicated test databases prefixed with `test_` (e.g. `test_posthog`, `test_posthog_persons`).
- Under `pytest-django`:
  - `--reuse-db` dramatically reduces test startup latency by skipping schema migrations across runs.
  - To prevent migration drift between branches, add `--create-db` or recreate `.enve/data/postgres` when testing schema/migration PRs.
- ClickHouse runs in-process on `:8123` with ephemeral table engines (`posthog_test`), avoiding cross-test contamination without needing container teardowns.

---

## 6. PR Verification & CI Parity Insights

### Automated Diff Fetching & Shadow Evaluation

- PR diffs can be directly piped via `gh pr diff <id>` or fallback raw patch URLs (`https://patch-diff.githubusercontent.com/raw/PostHog/posthog/pull/<id>.diff`).
- Applying PR diffs in temporary shadow working states allows testing remote pull requests locally without switching branches, rebasing, or stashing current work.
- **Coverage Confidence**:
  - Printing **provenance** (`source_file -> impacted_tests`) is critical for developer trust. Seeing that an added helper in a product module was only imported by one test explains why the local runner executed 1 test instead of 350.
  - Comparing local execution time against the GitHub Status Rollup (`statusCheckRollup`) immediately quantifies exact developer time saved per run.
