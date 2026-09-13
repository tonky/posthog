# PostHog Developer Tooling Catalog

This document details the tools, frameworks, and utilities used to run, build, scope, and test PostHog locally and in CI.

---

## 1. Tool Index

| Tool                 | Purpose                                            | Primary Use Case                                                                                                                                                                                                      |
| :------------------- | :------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`enve`**           | **Universal Hermetic Environment & Orchestration** | Declares and delivers all hermetic toolchains (Node, Go, Rust, uv, developer CLIs) and runs all microservices (Postgres, Redis, ClickHouse, Tansu, Temporal, SeaweedFS) rootlessly on localhost/tmpfs without Docker. |
| **`just`**           | Modern Command Runner                              | Replacement for complex Makefiles; orchestrates service lifecycles, test scoping, and dev tasks.                                                                                                                      |
| **`snob_lib`**       | Python AST Dependency Tracer                       | Scans Python codebase AST to find all tests transitively importing a given file.                                                                                                                                      |
| **`jest`**           | Frontend Test Runner                               | Executes TypeScript / React / Kea unit and component tests with `--findRelatedTests`.                                                                                                                                 |
| **`pytest`**         | Python Backend Test Runner                         | Executes Django and product backend tests with database fixtures.                                                                                                                                                     |
| **`uv`**             | **Python Runtime & Tool Authority**                | Fast hermetic Python runtime (CPython 3.13.13), virtualenv management, dependency resolution, and script execution.                                                                                                   |
| **`pnpm`**           | Fast Node Package Manager                          | Strict dependency management and workspace filtering (`pnpm --filter=@posthog/frontend ...`).                                                                                                                         |
| **`ruff`**           | Python Linter & Formatter                          | Sub-100ms Python formatting and linting (`ruff check . --fix`).                                                                                                                                                       |
| **`evaluate_pr.py`** | Multi-level PR Scoping Tool                        | Fetches remote PR diffs, determines affected components/tests, runs them, and compares with CI.                                                                                                                       |

---

## 2. Tool Workflows & Recipes

### 1. Universal Hermetic Environment & Services via `enve` & `just`

We use `enve` as the single unifying foundation for everything:

- **Hermetic Toolchains**: Compilers and runtimes (Node, Rust, Go), Python package & runtime manager (`uv`), and developer tools (`just`, `watchexec`, `ripgrep`, `jq`) are managed and pinned via `enve.cue` and `enve.lock`.
- **Zero-Daemon Microservices**: All datastores and services run in-process on localhost against tmpfs/RAM without Docker.

- Configuration: `enve.cue` (pinned by `enve.lock`)
- Start background services:

  ```bash
  just services-up
  ```

  Starts Postgres (15432), Redis (16379), ClickHouse (8123/9000), Tansu (19092), Temporal (7233), SeaweedFS (19000).

- Check running services:

  ```bash
  just services-ps
  ```

- Stop services:

  ```bash
  just services-down
  ```

### 2. PR Evaluation & Impact Scoping (`showcase/scripts/evaluate_pr.py`)

- Evaluates any GitHub PR URL or PR number against local scoped runners:

  ```bash
  just eval-pr https://github.com/PostHog/posthog/pull/98893
  ```

  or by number:

  ```bash
  just eval-pr 99503
  ```

- **What it does**:
  1. Fetches PR metadata and git diff via `gh api`.
  2. Classifies changed files into Backend, Frontend, Rust, or Configuration.
  3. Uses `snob_lib` to compute the exact affected backend tests.
  4. Uses `jest --findRelatedTests` to resolve affected frontend test suites.
  5. Displays clear per-file impact attribution (e.g. `constants.py -> test_learning_analyzer.py`).
  6. Skips Rust services to prevent long compile times.
  7. Runs only the affected tests against local services and compares execution time & coverage against CI.

### 3. Local Scoped Testing

- Run backend tests affected by local unstaged/staged git changes:

  ```bash
  just test-affected
  ```

- Run frontend tests affected by local git changes:

  ```bash
  just test-affected-frontend
  ```

---

## 3. Tool Tips & Best Practices

1. **Use `enve` Everywhere for Hermetic Parity**:
   - Run commands inside the `enve` environment or let `just` orchestrate through `enve`.
   - Never rely on ambient host-installed toolchains or global Homebrew packages — `enve` pins all binaries (Python, Node, Go, Rust, and tools) deterministically.
2. **Keep Python Fast with `uv`**:
   - Leverage `uv` for ultra-fast virtualenv creation and package installation within the hermetic workspace.
3. **Zero Docker Overhead for Unit & Integration Tests**:
   - Run `enve` microservices on RAM disks/tmpfs whenever testing backend or frontend changes.
4. **Instant Database Hydration via Schema Snapshots (`just snapshot-db`)**:
   - Rather than waiting 3+ minutes for Django to apply 2,690+ migrations on fresh databases, `showcase/snapshots/test_posthog.sql.gz` hydrates the full schema + migration state in **1.18 seconds**.
   - `enve.cue` automatically hydrates empty databases on first startup.
   - Run `just snapshot-db` to refresh the committed snapshot whenever upstream squashes or lands major schema changes.
5. **Optimized Frontend Test Execution & 50% CPU Cap**:
   - `frontend/jest.config.ts` pins `maxWorkers: '50%'` by default in local dev, preventing Jest from launching 9–10 workers and freezing macOS during large test runs.
   - `pnpm --filter=@posthog/frontend test <file>` now seamlessly runs individual test files without defaulting to the entire monolithic test shard.
   - Jest polyfills (`jest.polyfills.js`) automatically silence `@mswjs/interceptors` debug logging, avoiding stdout formatting storms during tests.
6. **Always Inspect Scoped Attribution**:
   - If `snob_lib` or `jest` identifies an unexpectedly large number of tests, check for imports of root barrel files (`urls.ts`, `settings.py`).
