# PostHog Developer Tooling Catalog

This document details the tools, frameworks, and utilities used to run, build, scope, and test PostHog locally and in CI.

---

## 1. Tool Index

| Tool                 | Purpose                           | Primary Use Case                                                                                             |
| :------------------- | :-------------------------------- | :----------------------------------------------------------------------------------------------------------- |
| **`enve`**           | Rootless Service Orchestration    | Runs Postgres, Redis, ClickHouse, Tansu, Temporal, and SeaweedFS directly on localhost/tmpfs without Docker. |
| **`just`**           | Modern Command Runner             | Replacement for complex Makefiles; orchestrates service lifecycles, test scoping, and dev tasks.             |
| **`snob_lib`**       | Python AST Dependency Tracer      | Scans Python codebase AST to find all tests transitively importing a given file.                             |
| **`jest`**           | Frontend Test Runner              | Executes TypeScript / React / Kea unit and component tests with `--findRelatedTests`.                        |
| **`pytest`**         | Python Backend Test Runner        | Executes Django and product backend tests with database fixtures.                                            |
| **`uv`**             | Fast Python Package & Tool Runner | Ultra-fast virtualenv management, dependency resolution, and script execution.                               |
| **`pnpm`**           | Fast Node Package Manager         | Strict dependency management and workspace filtering (`pnpm --filter=@posthog/frontend ...`).                |
| **`ruff`**           | Python Linter & Formatter         | Sub-100ms Python formatting and linting (`ruff check . --fix`).                                              |
| **`evaluate_pr.py`** | Multi-level PR Scoping Tool       | Fetches remote PR diffs, determines affected components/tests, runs them, and compares with CI.              |

---

## 2. Tool Workflows & Recipes

### 1. Rootless Services via `enve` & `just`

- Configuration: `showcase/enve.cue`
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

1. **Keep Python Fast with `uv`**:
   - Always run Python commands and scripts using `uv run python ...` or through `just` recipes to leverage cached virtual environments.
2. **Avoid Docker Overhead for Unit & Integration Tests**:
   - Use `enve` services on RAM disks/tmpfs whenever testing backend or frontend changes.
3. **Always Inspect Scoped Attribution**:
   - If `snob_lib` or `jest` identifies an unexpectedly large number of tests, check for imports of root barrel files (`urls.ts`, `settings.py`).
