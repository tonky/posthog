package replay

import "list"

_golangciLint: "golangci-lint run --timeout=5m --allow-parallel-runners"

_recordGo:    {cpus: 2, memory_mb: 512}
_recordPy:    {cpus: 1.5, memory_mb: 1536}
_recordJs:    {cpus: 3, memory_mb: 1024}
_recordCargo: {cpus: 3, memory_mb: 3072}

_tsVitest: {
	technology:       "typescript"
	depends_on:       ["js-root"]
	resources:        {cpus: 2, memory_mb: 768}
	test:             "pnpm exec vitest run {relative_targets}"
	recorder:         "trace"
	record_resources: _recordJs
}

_goModule: {
	technology:       "go"
	depends_on:       ["root"]
	recorder:         "trace"
	record_resources: _recordGo
}

pipeline: components: {
	"github_scripts": {
		name:       "github_scripts"
		title:      "CI scripts"
		technology: ["python", "javascript"]
		root:       "."
		depends_on: ["py-root", "pytest_plugins"]
		workspace_scope: include: [
			".github/workflows", "proto", "rust", "nodejs",
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
		name: "desktop", title: "PostHog desktop app", technology: "typescript"
		root: "products/desktop", depends_on: ["root"]
	}
	"cli": {
		name:             "cli"
		title:            "PostHog Developer CLI"
		description:      "PostHog Developer CLI in Rust"
		technology:       "rust"
		root:             "cli"
		depends_on:       ["root"]
		watch_paths:      ["cli/**", "dist-workspace.toml", "clippy.toml", "showcase/scripts/run_cargo_tests.sh", "rust/cymbal/tests/static/native/**"]
		fmt:              "cargo fmt --all -- --check"
		lint:             "cargo clippy --all-targets --all-features -- -D warnings"
		shards:           1
		test:             "../showcase/scripts/run_cargo_tests.sh cli --all-features -- {targets}"
		recorder:         "own_linux"
		record_resources: _recordCargo
		target_scope:     tests: ["cli/src/lib.rs", "cli/tests/*.rs"]
	}
	"funnel_udf": {
		name:             "funnel_udf"
		title:            "PostHog ClickHouse Funnel UDF"
		description:      "PostHog ClickHouse Funnel User Defined Function in Rust"
		technology:       "rust"
		root:             "funnel-udf"
		depends_on:       ["root"]
		watch_paths:      ["funnel-udf/**", "showcase/scripts/run_cargo_tests.sh"]
		test:             "../showcase/scripts/run_cargo_tests.sh funnel-udf -- {targets}"
		recorder:         "own_linux"
		record_resources: _recordCargo
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
		watch_paths: ["clickhouse-udfs/**", "showcase/scripts/run_go_tests.sh"]
		test:        "../showcase/scripts/run_go_tests.sh --module util --bench {targets}"
		target_scope: {
			tests: ["clickhouse-udfs/**/*_test.go"]
			rules: [{match: ["clickhouse-udfs/**"], engine: "reach"}]
		}
	}
	"terraform": {
		name: "terraform", title: "PostHog Infrastructure as Code"
		description: "PostHog Terraform & Terragrunt Cloud Infrastructure"
		root: "terraform", depends_on: ["root"]
	}
	"llm_gateway": {
		name: "llm_gateway", title: "LLM gateway", technology: "python"
		root: "services/llm-gateway", depends_on: ["root", "build_once"]
		jobs: test: {
			name: "Test", shards: 1, recorder: "trace", record_resources: _recordPy
			tasks: [
				{name: "Install", command: "cd ../.. && showcase/scripts/build_once.sh llm-gateway-venv services/llm-gateway/.venv/.enact-build-key services/llm-gateway/pyproject.toml services/llm-gateway/uv.lock -- uv --directory services/llm-gateway sync --frozen --dev --python \"$(command -v python3)\""},
				{name: "Run Tests", command: "env -u AWS_DEFAULT_REGION -u AWS_REGION -u LLM_GATEWAY_BEDROCK_REGION_NAME uv run --no-sync pytest -o addopts='' {relative_targets}"},
			]
		}
		target_scope: tests: ["services/llm-gateway/tests/**/test_*.py"]
	}
	"deltalite": {
		name: "deltalite", title: "Deltalite Python parity tests", technology: "python"
		root: "rust/deltalite/python", depends_on: ["py-root", "build_once"]
		workspace_scope: {include_dependencies: false, include: ["rust"]}
		watch_paths:     ["rust/deltalite/**"]
		jobs: test: {
			name: "Test", recorder: "trace", record_resources: _recordPy
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
		target_scope:    tests: ["services/agent-proxy/tests/**/*.test.ts"]
	}
	"oauth_proxy": _tsVitest & {
		name: "oauth_proxy", title: "OAuth proxy", root: "services/oauth-proxy"
		typecheck:    "pnpm typecheck"
		target_scope: tests: ["services/oauth-proxy/tests/**/*.test.ts"]
	}
	"integration_service": _tsVitest & {
		name: "integration_service", title: "Integration service", root: "services/integration-service"
		fmt: "pnpm run format:check", lint: "pnpm exec oxlint --quiet src tests", typecheck: "pnpm run typecheck", build: "pnpm run build"
		target_scope: tests: ["services/integration-service/tests/**/*.test.ts"]
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
		name: "hogql_language_service", title: "HogQL language service", root: "services/hogql-language-service"
		watch_paths: ["services/hogql-language-service/**", "showcase/scripts/run_go_tests.sh"]
		test:        "HOGQL_LANGUAGE_SERVICE_ENFORCE_LATENCY_BUDGET=1 ../../showcase/scripts/run_go_tests.sh {targets}"
		target_scope: {
			tests: ["services/hogql-language-service/**/*_test.go"]
			rules: [{match: ["services/hogql-language-service/**"], engine: "reach"}]
		}
	}
	"phrocs": _goModule & {
		name: "phrocs", title: "phrocs process runner", root: "tools/phrocs"
		watch_paths: ["tools/phrocs/**", "showcase/scripts/run_go_tests.sh"]
		lint: _golangciLint, test: "../../showcase/scripts/run_go_tests.sh {targets}"
		target_scope: {
			tests: ["tools/phrocs/**/*_test.go"]
			rules: [{match: ["tools/phrocs/**"], engine: "reach"}]
		}
	}
	"hobby_installer": _goModule & {
		name: "hobby_installer", title: "Hobby installer", root: "bin/hobby-installer"
		watch_paths: ["bin/hobby-installer/**", "showcase/scripts/run_go_tests.sh"]
		lint:        _golangciLint
		build:       "go build -ldflags \"-s -w\" -o ../hobby-installer-development . && rm -f ../hobby-installer-development"
		test:        "../../showcase/scripts/run_go_tests.sh {targets}"
		target_scope: {
			tests: ["bin/hobby-installer/**/*_test.go"]
			rules: [{match: ["bin/hobby-installer/**"], engine: "reach"}]
		}
	}
	"query_performance_ai": {
		name: "query_performance_ai", title: "Query performance AI", technology: "python"
		root: "tools/query-performance-ai", depends_on: ["py-root"]
		test: "cd ../.. && uv run --no-sync pytest {targets}", recorder: "trace", record_resources: _recordPy
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
	"mcp_integration_harness": {
		name: "mcp_integration_harness", title: "MCP integration runner", technology: ["python", "typescript"]
		root: ".", depends_on: ["live_harness"], watch_paths: ["showcase/scripts/run_mcp_integration.sh"]
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
			worker: "standard", recorder: "own", resources: {cpus: 4, memory_mb: 12288}, needs: _mcpUiAppsNeeds
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
