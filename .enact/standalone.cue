package replay

import "list"

_golangciLint: "golangci-lint run --timeout=5m --allow-parallel-runners"

_recordGo:    {cpus: 2, memory_mb: 512}
_recordPy:    {cpus: 1.5, memory_mb: 1536}
_recordJs:    {cpus: 3, memory_mb: 1024}
_recordCargo: {cpus: 3, memory_mb: 3072}

_tsVitest: {
	root:             string
	technology:       "typescript"
	depends_on:       ["js-root"]
	resources:        {cpus: 2, memory_mb: 768}
	test:             "pnpm exec vitest run {relative_targets}"
	recorder:         "trace"
	record_resources: _recordJs
	target_scope: tests: [...string] | *["\(root)/tests/**/*.test.ts"]
}

_goModule: {
	root:             string
	technology:       "go"
	depends_on:       ["root"]
	watch_paths:      ["\(root)/**", "showcase/scripts/run_go_tests.sh"]
	recorder:         "trace"
	record_resources: _recordGo
	target_scope: {
		tests: ["\(root)/**/*_test.go"]
		rules: [{match: ["\(root)/**"], engine: "reach"}]
	}
}

_rustCargoCrate: {
	technology:       "rust"
	depends_on:       ["root"]
	recorder:         "own_linux"
	record_resources: _recordCargo
}

pipeline: components: {
	"github_scripts": {
		name:       "github_scripts"
		title:      "CI scripts"
		technology: ["python", "javascript"]
		root:       "."
		depends_on: ["py-root", "pytest_plugins"]
		workspace_scope: include: [
			".github/workflows", ".github/actions", ".depot/actions", "proto", "rust", "nodejs",
			"docs/onboarding/package.json", "frontend/@posthog/lemon-ui/package.json",
			"packages/llm-normalizer/package.json", "packages/quill/package.json",
			"packages/quill/apps/storybook/package.json", "packages/quill/packages/blocks/package.json",
			"packages/quill/packages/charts/package.json", "packages/quill/packages/components/package.json",
			"packages/quill/packages/primitives/package.json", "packages/quill/packages/quill/package.json",
			"packages/quill/packages/tokens/package.json", "playwright/package.json",
			"services/agent-proxy/package.json", "services/integration-service/package.json",
			"services/oauth-proxy/package.json", "services/stripe-app/package.json",
			"tools/dagster_test_selection.py", "tools/openapi-codegen/package.json",
			"tools/query-performance-ai/query_performance_ai/sandboxed_autoresearch_agent/pi_plugin/package.json",
			"tools/snob_backend_test_selection_shadow.py",
			"tools/test_selection_verdict.py", "tools/test_dagster_test_selection.py",
			"tools/test_snob_backend_test_selection_shadow.py", "tools/test_test_selection_verdict.py",
			"tools/testmon_high_fanout_files.txt", "tools/workflow-plan/package.json", "frontend/bin/ci-report",
			"frontend/src/queries/schema.json", ".semgrep/rules/security/idor-team-scoped-models.yaml",
			"rust/feature-flags/src/properties",
		]
		watch_paths: [
			".github/scripts/**", "frontend/bin/ci-report/**", "tach.toml",
			"tools/*.py", "tools/testmon_high_fanout_files.txt", "proto/**",
			".github/workflows/ci-backend.yml", ".depot/workflows/ci-backend.yml",
			".github/new-events-schema-targets.txt", "showcase/scripts/run_ci_scripts_tests.sh",
		]
		test:             "showcase/scripts/run_ci_scripts_tests.sh {targets}"
		recorder:         "trace"
		record_resources: _recordPy
		recorded_by:      ["enact-node"]
		target_scope: {
			incidental_reads: ["posthog/**", "products/**", "ee/**", "common/**"]
			tests: [
				".github/scripts/**/test_*.py",
				".github/scripts/**/*.test.{js,mjs}",
				"tools/test_snob_backend_test_selection_shadow.py",
				"tools/test_test_selection_verdict.py",
			]
			not_run: [{
				tests:  [".github/scripts/*/**/*"]
				reason: "ci-scripts.yml runs the top-level files only (`.github/scripts/test_*.py`, `*.test.js`, `*.test.mjs`); desktop-ci.yml runs none of desktop/'s tests"
			}]
		}
	}
	"owners_yaml": {
		name: "owners_yaml", title: "owners.yaml resolver", technology: "python"
		root: "packages/owners-yaml", depends_on: ["py-root"]
		watch_paths: ["packages/owners-yaml/**", "owners.yaml", "{.agents,.github,docs,ee,frontend,nodejs,packages,posthog,products,rust,services}/**/owners.yaml"]
	}
	"desktop": {
		// A cold pnpm store fetches ~4,000 packages: about 13 min on the fork's runners, past
		// the 600 s default step limit, so the install never finished to warm the store.
		_install: {
			name:    "Install"
			dir:     "."
			timeout: "30m"
			once: {
				key:     "desktop-node-modules"
				inputs:  ["products/desktop/package.json", "products/desktop/pnpm-lock.yaml", "products/desktop/pnpm-workspace.yaml", "packages/agent/package.json", "packages/agent/pnpm-lock.yaml", "packages/agent/pnpm-workspace.yaml"]
				outputs: ["products/desktop/node_modules"]
			}
			command: "showcase/scripts/build_once.sh desktop-node-modules products/desktop/node_modules/.enact-build-key products/desktop/package.json products/desktop/pnpm-lock.yaml products/desktop/pnpm-workspace.yaml packages/agent/package.json packages/agent/pnpm-lock.yaml packages/agent/pnpm-workspace.yaml -- bash -c 'SKIP_ELECTRON_REBUILD=1 pnpm --dir products/desktop install --frozen-lockfile && showcase/scripts/exclusive.sh agent-node-modules node products/desktop/scripts/build-agent-workspace.mjs'"
		}
		name:            "desktop"
		title:           "PostHog desktop app"
		technology:      "typescript"
		root:            "products/desktop"
		depends_on:      ["root", "build_once"]
		// Contract tests read backend files they mirror (model costs, task kinds, canvas SDK).
		workspace_scope: include: ["packages/agent", "services/llm-gateway/src/llm_gateway/rate_limiting/model_cost_overrides.py", "products/tasks/backend/models.py", "products/canvas/packages/canvas_builder/manifest.json", "products/canvas/packages/canvas_builder/canvas-sdk.mjs"]
		watch_paths:     ["products/desktop/**", "packages/agent/**"]
		jobs: {
			lint: {
				name: "Lint"
				tasks: [
					_install,
					{name: "Lint", command: "pnpm exec biome ci . && pnpm --dir ../../packages/agent exec biome ci . && node scripts/check-host-boundaries.mjs"},
				]
			}
			// Upstream runs both on depot-ubuntu-24.04-4 (4 vCPU) with a 30 min limit. Measured
			// cold (turbo cache forced off, 18-core Mac): typecheck peaks 8.8 GB (turbo's ten tsc at
			// once), the tests 7.8 GB over 2,860 CPU-s, which on 2 cores ran past the 600 s default
			// step limit; under the 1 GB default the resource watcher killed typecheck at 3.5 GB.
			typecheck: {
				name:      "Typecheck"
				resources: {cpus: 4.0, memory_mb: 9216}
				tasks: [
					_install,
					{name: "Typecheck", command: "pnpm run typecheck", timeout: "30m"},
				]
			}
			test: {
				name:      "Test"
				shards:    1
				resources: {cpus: 4.0, memory_mb: 8192}
				tasks: [
					_install,
					{name: "Run Tests", command: "node scripts/rebuild-better-sqlite3-node.mjs && pnpm test", timeout: "30m"},
				]
			}
		}
	}
	"cli": _rustCargoCrate & {
		name:         "cli"
		title:        "PostHog Developer CLI"
		description:  "PostHog Developer CLI in Rust"
		root:         "cli"
		watch_paths:  ["cli/**", "dist-workspace.toml", "clippy.toml", "showcase/scripts/run_cargo_tests.sh", "rust/cymbal/tests/static/native/**"]
		fmt:          "cargo fmt --all -- --check"
		lint:         "cargo clippy --all-targets --all-features -- -D warnings"
		shards:       1
		test:         "../showcase/scripts/run_cargo_tests.sh cli --all-features -- {targets}"
		target_scope: tests: ["cli/src/lib.rs", "cli/tests/*.rs"]
	}
	"funnel_udf": _rustCargoCrate & {
		name:        "funnel_udf"
		title:       "PostHog ClickHouse Funnel UDF"
		description: "PostHog ClickHouse Funnel User Defined Function in Rust"
		root:        "funnel-udf"
		watch_paths: ["funnel-udf/**", "showcase/scripts/run_cargo_tests.sh"]
		test:        "../showcase/scripts/run_cargo_tests.sh funnel-udf -- {targets}"
		target_scope: {
			tests: ["funnel-udf/src/main.rs"]
			rules: [{match: ["funnel-udf/**"], engine: "reach"}]
		}
	}
	"clickhouse_udfs": _goModule & {
		name:        "clickhouse_udfs"
		title:       "PostHog ClickHouse UDFs"
		description: "PostHog ClickHouse User Defined Functions in Go"
		root:        "clickhouse-udfs"
		test:        "../showcase/scripts/run_go_tests.sh --module util --bench {targets}"
	}
	"terraform": {
		name: "terraform", title: "PostHog Infrastructure as Code"
		description: "PostHog Terraform & Terragrunt Cloud Infrastructure"
		root: "terraform", depends_on: ["root"]
	}
	"llm_gateway": {
		name: "llm_gateway", title: "LLM gateway", technology: "python"
		root: "services/llm-gateway", depends_on: ["root", "build_once"]
		shards: 1, recorder: "trace", record_resources: _recordPy
		jobs: test: {
			name: "Test"
			tasks: [
				{
					name: "Install"
					dir:  "."
					once: {
						key:     "llm-gateway-venv"
						inputs:  ["services/llm-gateway/pyproject.toml", "services/llm-gateway/uv.lock"]
						outputs: ["services/llm-gateway/.venv"]
					}
					command: "showcase/scripts/build_once.sh llm-gateway-venv services/llm-gateway/.venv/.enact-build-key services/llm-gateway/pyproject.toml services/llm-gateway/uv.lock -- uv --directory services/llm-gateway sync --frozen --dev --python \"$(command -v python3)\""
				},
				{
					name:      "Run Tests"
					command:   "uv run --no-sync pytest -o addopts='' {relative_targets}"
					unset_env: ["AWS_DEFAULT_REGION", "AWS_REGION", "LLM_GATEWAY_BEDROCK_REGION_NAME"]
				},
			]
		}
		target_scope: tests: ["services/llm-gateway/tests/**/test_*.py"]
	}
	"deltalite": {
		name: "deltalite", title: "Deltalite Python parity tests", technology: "python"
		root: "rust/deltalite/python", depends_on: ["py-root", "build_once"]
		workspace_scope: {include_dependencies: false, include: ["rust"]}
		watch_paths:     ["rust/deltalite/**"]
		recorder:        "trace", record_resources: _recordPy
		jobs: test: {
			name: "Test"
			tasks: [
				{
					name: "Install"
					dir:  "."
					once: {
						key:     "deltalite-venv"
						inputs:  ["pyproject.toml", "rust/deltalite/python/pyproject.toml", "rust/deltalite/python/Cargo.toml"]
						outputs: ["rust/deltalite/python/.venv"]
					}
					command: "showcase/scripts/build_once.sh deltalite-venv rust/deltalite/python/.venv/.enact-build-key pyproject.toml rust/deltalite/python/pyproject.toml rust/deltalite/python/Cargo.toml -- bash -c 'uv venv --clear rust/deltalite/python/.venv --python \"$(command -v python3)\" && pin() { grep -oE \"\\\"${1}[^\\\"]*\\\"\" pyproject.toml | tr -d \"\\\"\" | head -1; } && VIRTUAL_ENV=$PWD/rust/deltalite/python/.venv uv pip install pytest \"$(pin \"deltalake\\[pyarrow\\]==\")\" \"$(pin \"pyarrow==\")\" \"$(pin \"duckdb~=\")\" \"$(pin \"deltalite==\")\"'"
				},
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
	"stripe_mock": {
		name: "stripe_mock", title: "Stripe API mock", technology: "python"
		root: "services/stripe-mock", depends_on: ["root"]
	}
	"agent_proxy": _tsVitest & {
		name: "agent_proxy", title: "Agent proxy", root: "services/agent-proxy"
		workspace_scope: include: ["ee/hogai/sandbox"]
		watch_paths:     ["services/agent-proxy/**", "ee/hogai/sandbox/turn_event_contract.json"]
		fmt:             "pnpm exec oxfmt --check 'src/**/*.ts' 'tests/**/*.ts' 'scripts/**/*.ts'"
		lint:            "pnpm exec oxlint --quiet"
		typecheck:       "pnpm typecheck"
	}
	"oauth_proxy": _tsVitest & {
		name: "oauth_proxy", title: "OAuth proxy", root: "services/oauth-proxy"
		typecheck: "pnpm typecheck"
	}
	"integration_service": _tsVitest & {
		name: "integration_service", title: "Integration service", root: "services/integration-service"
		fmt: "pnpm run format:check", lint: "pnpm exec oxlint --quiet src tests", typecheck: "pnpm run typecheck", build: "pnpm run build"
	}
	"stripe_app": {
		name: "stripe_app", title: "Stripe app", technology: "typescript"
		root: "services/stripe-app", depends_on: ["js-root"]
	}
	"openapi_codegen": _tsVitest & {
		name: "openapi_codegen", title: "OpenAPI code generator", root: "tools/openapi-codegen"
		target_scope: tests: ["tools/openapi-codegen/tests/**/*.test.mjs"]
	}
	"hogql_language_service": _goModule & {
		name:      "hogql_language_service", title: "HogQL language service", root: "services/hogql-language-service"
		resources: {cpus: 4, memory_mb: 1024}
		test:      "HOGQL_LANGUAGE_SERVICE_ENFORCE_LATENCY_BUDGET=1 ../../showcase/scripts/run_go_tests.sh {targets} || HOGQL_LANGUAGE_SERVICE_ENFORCE_LATENCY_BUDGET=1 ../../showcase/scripts/run_go_tests.sh {targets}"
	}
	"phrocs": _goModule & {
		name: "phrocs", title: "phrocs process runner", root: "tools/phrocs"
		lint: _golangciLint, test: "../../showcase/scripts/run_go_tests.sh {targets}"
	}
	"hobby_installer": _goModule & {
		name:  "hobby_installer", title: "Hobby installer", root: "bin/hobby-installer"
		lint:  _golangciLint
		build: "go build -ldflags \"-s -w\" -o ../hobby-installer-development . && rm -f ../hobby-installer-development"
		test:  "../../showcase/scripts/run_go_tests.sh {targets}"
	}
	"query_performance_ai": {
		name: "query_performance_ai", title: "Query performance AI", technology: "python"
		root: "tools/query-performance-ai", depends_on: ["py-root"]
		test: {
			dir:     "."
			command: "uv run --no-sync pytest {targets}"
		}
		recorder: "trace", record_resources: _recordPy
		target_scope: {
			tests:          ["tools/query-performance-ai/query_performance_ai/**/test_*.py"]
			default_target: "tools/query-performance-ai/query_performance_ai"
		}
	}
	"hedgebox_dummy": {
		name: "hedgebox_dummy", title: "Hedgebox demo app", technology: "typescript"
		root: "tools/hedgebox-dummy", depends_on: ["root"]
	}
	"hogbox_preview": {
		name: "hogbox_preview", title: "Hogbox preview environments", technology: "python"
		root: "tools/hogbox-preview", depends_on: ["py-root"]
	}
	"infra_scripts": {
		name: "infra_scripts", title: "Infrastructure scripts", technology: "python"
		root: "tools/infra-scripts", depends_on: ["py-root"]
	}
	"traffic_sim": {
		name: "traffic_sim", title: "Traffic simulator", technology: "python"
		root: "tools/traffic-sim", depends_on: ["root"]
	}
	"mcp_integration_harness": _harness & {
		name: "mcp_integration_harness", title: "MCP integration runner", technology: ["python", "typescript"]
		depends_on: ["live_harness"], watch_paths: ["showcase/scripts/run_mcp_integration.sh"]
	}
	"mcp_integration": {
		name:             "mcp_integration"
		title:            "MCP integration tests"
		description:      "The MCP server's tools driving a live PostHog API over HTTP"
		technology:       ["typescript", "python", "rust"]
		root:             "services/mcp/tests"
		cargo: workspace: "rust"
		depends_on:       ["mcp", "base", "proto", "frontend", "mcp_integration_harness"]
		workspace_scope:  include: list.Concat([_djangoTree, ["services/mcp", "rust", "proto", "docker", "infra", "frontend/src/queries"]])
		watch_paths: list.Concat([[
			"rust/persons_migrations/**", "showcase/scripts/live_footprint.py",
			"showcase/scripts/rust_footprint.py", "showcase/scripts/node_reads.mjs",
		], _liveFlagsRust])
		jobs: test: {
			worker: "standard", recorder: "own", resources: {cpus: 4, memory_mb: 11264}, record_resources: resources, needs: _mcpUiAppsNeeds
			tasks: [
				{name: "Build UI apps", command: "../../../showcase/scripts/build_mcp_ui_apps.sh"},
				{name: "Run Tests", command: "../../../showcase/scripts/run_mcp_integration.sh {targets}", timeout: "60m"},
			]
			target_scope: {
				fallback: "all"
				tests:    ["services/mcp/tests/**/*.integration.test.ts"]
				rules: [
					{match: ["posthog/dags/**", "products/*/dags/**"], action: "ignore"},
					{
						match: [
							"services/mcp/src/**/*.{ts,tsx,js,mjs}", "services/mcp/tests/**/*.ts",
							"products/*/mcp/**/*.{ts,tsx}", "frontend/src/**/*.{ts,tsx,js,jsx,mjs}",
							"products/*/frontend/**/*.{ts,tsx,js,jsx,mjs}",
						]
						engine:      "typescript"
						granularity: "file"
					},
					{
						match:       ["posthog/**/*.py", "ee/**/*.py", "common/**/*.py", "products/**/*.py"]
						engine:      "python"
						granularity: "file"
					},
				]
			}
		}
		uses: _liveServices
	}
}
