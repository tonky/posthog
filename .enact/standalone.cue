package replay

// Standalone projects: each its own package, module or crate, depending on nothing but
// the environment. Those without jobs are covered so a change to them selects them alone;
// the comment names the upstream workflow enact doesn't model yet.

// golangci-lint, as the Go modules' workflows run it. By default it takes a lock in the temp
// dir and quits when another instance holds it ("parallel golangci-lint is running"): one run's
// Go lint jobs side by side on a Mac, which gives shards no temp dir of their own, or two
// checkouts' runs. Its cache is safe to share.
_golangciLint: "golangci-lint run --timeout=5m --allow-parallel-runners"

// What one recording shard of a traced suite takes (`record_resources`): the `trace` recorder
// runs one test (Go) or test file (Python, vitest) at a time under the tracer. Calibrated on
// linux2 (arm64): Go 1.4-2.6 cores and 110-310 MB, Python 1-1.6 cores and 0.3-1.2 GB, vitest
// 1.6-3.5 cores and 0.3-0.75 GB.
_recordGo: {cpus: 2, memory_mb: 512}
_recordPy: {cpus: 1.5, memory_mb: 1536}
_recordJs: {cpus: 3, memory_mb: 1024}
// A Rust suite's recording (rust_footprint.py): its test run, then the build's inputs. cli:
// 2.9 cores, 2.3 GB.
_recordCargo: {cpus: 3, memory_mb: 3072}

pipeline: components: {
	// As ci-scripts.yml: the CI helpers' unit tests (Python and node:test).
	"github_scripts": {
		name:       "github_scripts"
		title:      "CI scripts"
		technology: ["python", "javascript"]
		// The repository: its suite holds tools/ tests too, and a suite lists its tests under
		// its root (a narrower root left them out of every selection).
		root:       "."
		// Some check scripts import the Django project.
		depends_on: ["py-root"]
		// What the tests read besides their own tree (ci-scripts.yml's sparse checkout):
		// trunk-impacted-targets.test.js walks proto/, rust/ and nodejs/ for their manifests.
		workspace_scope: include: [
			"proto",
			"rust",
			"nodejs",
			"tools/dagster_test_selection.py",
			"tools/snob_backend_test_selection_shadow.py",
			"tools/test_selection_verdict.py",
			"tools/test_dagster_test_selection.py",
			"tools/test_snob_backend_test_selection_shadow.py",
			"tools/test_test_selection_verdict.py",
			"tools/testmon_high_fanout_files.txt",
			"frontend/bin/ci-report",
			"frontend/src/queries/schema.json",
			".semgrep/rules/security/idor-team-scoped-models.yaml",
			"rust/feature-flags/src/properties",
		]
		watch_paths: [
			".github/scripts/**",
			// What the scripts import or read: the CI report's helpers, tach's module map.
			"frontend/bin/ci-report/**",
			"tach.toml",
			"tools/*.py",
			"tools/testmon_high_fanout_files.txt",
			// ci-scripts.yml's filter: trunk-impacted-targets.test.js fails on a proto tree its
			// table doesn't declare, and turbo-discover.test.js pins the Django segment table.
			"proto/**",
			".github/workflows/ci-backend.yml",
			".depot/workflows/ci-backend.yml",
			".github/new-events-schema-targets.txt",
			"showcase/scripts/run_ci_scripts_tests.sh",
		]
		// As ci-scripts.yml (run_ci_scripts_tests.sh): pytest, then node:test, from the root.
		// A recording traces each test file in a run of its own (Linux), a node:test file's
		// with the functions it ran.
		test:     "showcase/scripts/run_ci_scripts_tests.sh {targets}"
		recorder: "trace"

		record_resources: _recordPy

		recorded_by: ["enact-node"]
		target_scope: {
			// The workflow's files: the tools/ ones by name (a glob would take tests other jobs
			// run, and test_selection_verdict.py, the script under test).
			tests: [
				".github/scripts/**/test_*.py",
				".github/scripts/**/*.test.{js,mjs}",
				"tools/test_snob_backend_test_selection_shadow.py",
				"tools/test_test_selection_verdict.py",
			]
			not_run: [{
				tests: [".github/scripts/*/**/*"]
				reason: "ci-scripts.yml runs the top-level files only (`.github/scripts/test_*.py`, `*.test.js`, `*.test.mjs`); desktop-ci.yml runs none of desktop/'s tests"
			}]
		}
	}
	"owners_yaml": {
		name:       "owners_yaml"
		title:      "owners.yaml resolver"
		technology: "python"
		root:       "packages/owners-yaml"
		depends_on: ["py-root"]
		watch_paths: [
			"packages/owners-yaml/**",
			"owners.yaml",
			"**/owners.yaml",
		]
	}
	// A standalone pnpm workspace (own lockfile and Node pin): desktop-ci.yml and friends.
	"desktop": {
		name:       "desktop"
		title:      "PostHog desktop app"
		technology: "typescript"
		root:       "products/desktop"
		depends_on: ["root"]
	}
	"cli": {
		name:        "cli"
		title:       "PostHog Developer CLI"
		description: "PostHog Developer CLI in Rust"
		technology:  "rust"
		root:        "cli"
		depends_on: ["root"]
		// cargo-dist's release configuration for it, and clippy's configuration.
		// rust/cymbal/tests/static/native: the native binaries its symbol tests read.
		watch_paths: ["cli/**", "dist-workspace.toml", "clippy.toml", "showcase/scripts/run_cargo_tests.sh", "rust/cymbal/tests/static/native/**"]
		// As ci-cli.yml.
		fmt:  "cargo fmt --all -- --check"
		lint: "cargo clippy --all-targets --all-features -- -D warnings"
		// `cargo test --all-features`, by test binary; run_cargo_tests.sh records (enact trace
		// run, rust_footprint.py): on Linux.
		shards:   1
		test:     "../showcase/scripts/run_cargo_tests.sh cli --all-features -- {targets}"
		recorder: "own_linux"

		record_resources: _recordCargo
		// Its test binaries, each by its root file: the library's unit tests and the
		// integration tests (src/main.rs declares no module: it holds none).
		target_scope: tests: ["cli/src/lib.rs", "cli/tests/*.rs"]
	}
	"funnel_udf": {
		name:        "funnel_udf"
		title:       "PostHog ClickHouse Funnel UDF"
		description: "PostHog ClickHouse Funnel User Defined Function in Rust"
		technology:  "rust"
		root:        "funnel-udf"
		depends_on: ["root"]
		watch_paths: ["funnel-udf/**", "showcase/scripts/run_cargo_tests.sh"]
		// No upstream workflow lints or tests it: its `cargo test`, by test binary;
		// run_cargo_tests.sh records (enact trace run, rust_footprint.py): on Linux.
		test:     "../showcase/scripts/run_cargo_tests.sh funnel-udf -- {targets}"
		recorder: "own_linux"

		record_resources: _recordCargo
		// Its one test binary, the binary's unit tests, by its root file.
		target_scope: {
			tests: ["funnel-udf/src/main.rs"]
			rules: [{match: ["funnel-udf/**"], engine: "reach"}]
		}
	}
	"clickhouse_udfs": {
		name:        "clickhouse_udfs"
		title:       "PostHog ClickHouse UDFs"
		description: "PostHog ClickHouse User Defined Functions in Go"
		technology:  "go"
		root:        "clickhouse-udfs"
		depends_on: ["root"]
		watch_paths: ["clickhouse-udfs/**", "showcase/scripts/run_go_tests.sh"]
		// The module is util/, as ci-clickhouse-util-udfs.yml: its tests and benchmarks
		// (run_go_tests.sh: the selected tests, then their packages' benchmarks). It runs no
		// linter there (golangci-lint finds 19 issues); integration_test.sh needs docker. A
		// recording traces each test in a run of its own (Linux).
		test:     "../showcase/scripts/run_go_tests.sh --module util --bench {targets}"
		recorder: "trace"

		record_resources: _recordGo
		target_scope: {
			tests: ["clickhouse-udfs/**/*_test.go"]
			rules: [{match: ["clickhouse-udfs/**"], engine: "reach"}]
		}
	}
	"terraform": {
		name:        "terraform"
		title:       "PostHog Infrastructure as Code"
		description: "PostHog Terraform & Terragrunt Cloud Infrastructure"
		root:        "terraform"
		depends_on: ["root"]
		// No checks: upstream's only job (terragrunt-posthog.yaml) plans against AWS, and runs
		// no fmt check (7 files fail `tofu fmt -check`).
	}
	// Its own uv project: ci-llm-gateway.yml.
	"llm_gateway": {
		name:       "llm_gateway"
		title:      "LLM gateway"
		technology: "python"
		root:       "services/llm-gateway"
		depends_on: ["root", "build_once"]
		jobs: test: {
			name:     "Test"
			shards:   1
			recorder: "trace"

			record_resources: _recordPy
			tasks: [
				{name: "Install", command: "cd ../.. && showcase/scripts/build_once.sh llm-gateway-venv services/llm-gateway/.venv/.enact-build-key services/llm-gateway/pyproject.toml services/llm-gateway/uv.lock -- uv --directory services/llm-gateway sync --frozen --dev --python \"$(command -v python3)\""},
				{name: "Run Tests", command: "env -u AWS_DEFAULT_REGION -u AWS_REGION -u LLM_GATEWAY_BEDROCK_REGION_NAME uv run --no-sync pytest -o addopts='' {relative_targets}"},
			]
		}
		target_scope: tests: ["services/llm-gateway/tests/**/test_*.py"]
	}
	// ci-deltalite-python.yml: the differential parity suite for rust/deltalite against the
	// repository's pinned deltalake, pyarrow and duckdb versions.
	"deltalite": {
		name:       "deltalite"
		title:      "Deltalite Python parity tests"
		technology: "python"
		root:       "rust/deltalite/python"
		depends_on: ["py-root", "build_once"]
		workspace_scope: include: ["rust"]
		watch_paths: ["rust/deltalite/**"]
		jobs: test: {
			name:     "Test"
			recorder: "trace"

			record_resources: _recordPy
			tasks: [
				{name: "Install", command: "cd ../../.. && showcase/scripts/build_once.sh deltalite-venv rust/deltalite/python/.venv/.enact-build-key pyproject.toml rust/deltalite/python/pyproject.toml rust/deltalite/python/Cargo.toml -- bash -c 'uv venv --clear rust/deltalite/python/.venv --python \"$(command -v python3)\" && pin() { grep -oE \"\\\"${1}[^\\\"]*\\\"\" pyproject.toml | tr -d \"\\\"\" | head -1; } && VIRTUAL_ENV=$PWD/rust/deltalite/python/.venv uv pip install pytest \"$(pin \"deltalake\\[pyarrow\\]==\")\" \"$(pin \"pyarrow==\")\" \"$(pin \"duckdb~=\")\" \"$(pin \"deltalite==\")\"'"},
				{name: "Run Tests", command: "VIRTUAL_ENV=$PWD/.venv uv run --no-sync --active python -m pytest {relative_targets} -q"},
			]
		}
		target_scope: {
			tests: ["rust/deltalite/python/tests/**/test_*.py"]
			rules: [
				{match: ["rust/deltalite/python/**/*.py"], engine: "python", granularity: "file"},
				{match: ["rust/deltalite/**"], engine: "reach"},
			]
		}
	}
	// Its own uv project; nothing upstream tests it.
	"stripe_mock": {
		name:       "stripe_mock"
		title:      "Stripe API mock"
		technology: "python"
		root:       "services/stripe-mock"
		depends_on: ["root"]
	}
	// pnpm workspace packages: ci-agent-proxy.yml, ci-oauth-proxy.yml,
	// ci-integration-service.yml, ci-openapi-codegen.yml; the Stripe app has no CI.
	"agent_proxy": {
		name:       "agent_proxy"
		title:      "Agent proxy"
		technology: "typescript"
		root:       "services/agent-proxy"
		depends_on: ["js-root"]
		workspace_scope: include: ["ee/hogai/sandbox"]
		watch_paths: [
			"services/agent-proxy/**",
			"ee/hogai/sandbox/turn_event_contract.json",
		]
		fmt:       "pnpm exec oxfmt --check 'src/**/*.ts' 'tests/**/*.ts' 'scripts/**/*.ts'"
		lint:      "pnpm exec oxlint"
		typecheck: "pnpm typecheck"
		test:      "pnpm exec vitest run {relative_targets}"
		recorder:  "trace"

		record_resources: _recordJs
		target_scope: tests: ["services/agent-proxy/tests/**/*.test.ts"]
	}
	"oauth_proxy": {
		name:       "oauth_proxy"
		title:      "OAuth proxy"
		technology: "typescript"
		root:       "services/oauth-proxy"
		depends_on: ["js-root"]
		typecheck:  "pnpm typecheck"
		test:       "pnpm exec vitest run {relative_targets}"
		recorder:   "trace"

		record_resources: _recordJs
		target_scope: tests: ["services/oauth-proxy/tests/**/*.test.ts"]
	}
	"integration_service": {
		name:       "integration_service"
		title:      "Integration service"
		technology: "typescript"
		root:       "services/integration-service"
		depends_on: ["js-root"]
		fmt:        "pnpm run format:check"
		lint:       "pnpm run lint"
		typecheck:  "pnpm run typecheck"
		build:      "pnpm run build"
		test:       "pnpm exec vitest run {relative_targets}"
		recorder:   "trace"

		record_resources: _recordJs
		target_scope: tests: ["services/integration-service/tests/**/*.test.ts"]
	}
	"stripe_app": {
		name:       "stripe_app"
		title:      "Stripe app"
		technology: "typescript"
		root:       "services/stripe-app"
		depends_on: ["js-root"]
	}
	"openapi_codegen": {
		name:       "openapi_codegen"
		title:      "OpenAPI code generator"
		technology: "typescript"
		root:       "tools/openapi-codegen"
		depends_on: ["js-root"]
		test:       "pnpm exec vitest run {relative_targets}"
		recorder:   "trace"

		record_resources: _recordJs
		target_scope: tests: ["tools/openapi-codegen/tests/**/*.test.mjs"]
	}
	// Go modules: ci-hogql-language-service.yml, ci-phrocs.yml, ci-hobby-installer.yml.
	"hogql_language_service": {
		name:       "hogql_language_service"
		title:      "HogQL language service"
		technology: "go"
		root:       "services/hogql-language-service"
		depends_on: ["root"]
		watch_paths: ["services/hogql-language-service/**", "showcase/scripts/run_go_tests.sh"]
		test:     "HOGQL_LANGUAGE_SERVICE_ENFORCE_LATENCY_BUDGET=1 ../../showcase/scripts/run_go_tests.sh {targets}"
		recorder: "trace"

		record_resources: _recordGo
		target_scope: {
			tests: ["services/hogql-language-service/**/*_test.go"]
			rules: [{match: ["services/hogql-language-service/**"], engine: "reach"}]
		}
	}
	"phrocs": {
		name:       "phrocs"
		title:      "phrocs process runner"
		technology: "go"
		root:       "tools/phrocs"
		depends_on: ["root"]
		watch_paths: ["tools/phrocs/**", "showcase/scripts/run_go_tests.sh"]
		lint:     _golangciLint
		test:     "../../showcase/scripts/run_go_tests.sh {targets}"
		recorder: "trace"

		record_resources: _recordGo
		target_scope: {
			tests: ["tools/phrocs/**/*_test.go"]
			rules: [{match: ["tools/phrocs/**"], engine: "reach"}]
		}
	}
	"hobby_installer": {
		name:       "hobby_installer"
		title:      "Hobby installer"
		technology: "go"
		root:       "bin/hobby-installer"
		depends_on: ["root"]
		watch_paths: ["bin/hobby-installer/**", "showcase/scripts/run_go_tests.sh"]
		lint:     _golangciLint
		build:    "go build -ldflags \"-s -w\" -o ../hobby-installer-development . && rm -f ../hobby-installer-development"
		test:     "../../showcase/scripts/run_go_tests.sh {targets}"
		recorder: "trace"

		record_resources: _recordGo
		target_scope: {
			tests: ["bin/hobby-installer/**/*_test.go"]
			rules: [{match: ["bin/hobby-installer/**"], engine: "reach"}]
		}
	}
	// ci-python.yml runs its tests in the root uv project.
	"query_performance_ai": {
		name:       "query_performance_ai"
		title:      "Query performance AI"
		technology: "python"
		root:       "tools/query-performance-ai"
		depends_on: ["py-root"]
		// From the root, as ci-python.yml (pytest.ini's pythonpath makes the package
		// importable; its `--ignore` keeps it out of the Django suites, not this one), without
		// the Django suites' recorder plugin: a recording traces each test file in a run of its
		// own (Linux).
		test:     "cd ../.. && uv run --no-sync pytest {targets}"
		recorder: "trace"

		record_resources: _recordPy
		target_scope: {
			tests: ["tools/query-performance-ai/query_performance_ai/**/test_*.py"]
			default_target: "tools/query-performance-ai/query_performance_ai"
		}
	}
	// Developer and ops tools no upstream CI job runs.
	"hedgebox_dummy": {
		name:       "hedgebox_dummy"
		title:      "Hedgebox demo app"
		technology: "typescript"
		root:       "tools/hedgebox-dummy"
		// Its own pnpm workspace and lockfile.
		depends_on: ["root"]
	}
	"hogbox_preview": {
		name:       "hogbox_preview"
		title:      "Hogbox preview environments"
		technology: "python"
		root:       "tools/hogbox-preview"
		depends_on: ["py-root"]
	}
	"infra_scripts": {
		name:       "infra_scripts"
		title:      "Infrastructure scripts"
		technology: "python"
		root:       "tools/infra-scripts"
		depends_on: ["py-root"]
	}
	"traffic_sim": {
		name:       "traffic_sim"
		title:      "Traffic simulator"
		technology: "python"
		root:       "tools/traffic-sim"
		depends_on: ["root"]
	}
}
