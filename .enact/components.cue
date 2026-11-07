package replay

import (
	"list"
	"enact.dev/schema"
)

// Root-anchored globs: `docs/**` matches top-level docs/ only; `**/` matches at any depth.

_backendServices: [
	{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres, title: "Reads & writes app metadata"},
	{protocol: schema.#Protocol.Redis, target: pipeline.services.redis, title: "Caches sessions & flags"},
	{protocol: schema.#Protocol.Kafka, target: pipeline.services.kafka, title: "Event streaming broker"},
	{protocol: schema.#Protocol.Http, target: pipeline.services.clickhouse, title: "Analytics DBMS"},
	{protocol: schema.#Protocol.Http, target: pipeline.services.seaweedfs, title: "Object storage for staging & recordings"},
	{protocol: schema.#Protocol.Grpc, target: pipeline.services.temporal, title: "Workflow engine for async tasks"},
	{protocol: schema.#Protocol.Http, target: pipeline.services.azurite, title: "Azure blob storage for batch exports"},
]
_ingestionServices: [
	{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres},
	{protocol: schema.#Protocol.Redis, target: pipeline.services.redis},
	{protocol: schema.#Protocol.Kafka, target: pipeline.services.kafka},
	{protocol: schema.#Protocol.Http, target: pipeline.services.clickhouse},
]
_liveServices: [
	{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres},
	{protocol: schema.#Protocol.Redis, target: pipeline.services.redis},
	{protocol: schema.#Protocol.Kafka, target: pipeline.services.kafka},
	{protocol: schema.#Protocol.Http, target: pipeline.services.clickhouse},
	{protocol: schema.#Protocol.Http, target: pipeline.services.seaweedfs},
	{protocol: schema.#Protocol.Grpc, target: pipeline.services.temporal},
]

_djangoMigrations: [
	"posthog/migrations/**", "ee/migrations/**",
	"posthog/management/commands/setup_test_environment.py",
]

_liveIngestionNode: [
	"nodejs/src/**", "nodejs/assets/**", "nodejs/package.json", "nodejs/tsconfig.json",
	"common/hogvm/typescript/src/**",
	"common/hogvm/typescript/{package.json,tsconfig.json,tsconfig.build.json,.parcelrc}",
	"common/replay-headless/src/**", "common/replay-headless/{package.json,tsconfig.json,build.mjs}",
	"common/replay-shared/src/**", "common/replay-shared/package.json",
	"rust/common/hogvm/**", "rust/replay-anonymizer/**", "rust/replay-anonymizer-node/**",
]
_liveIngestionNodeTests: [
	"nodejs/src/**/*.test.ts", "nodejs/src/**/__snapshots__/**", "nodejs/src/**/__tests__/**",
	"common/hogvm/typescript/src/**/*.test.ts", "common/hogvm/typescript/src/**/__snapshots__/**", "common/hogvm/typescript/src/**/__tests__/**",
	"common/replay-headless/src/**/*.test.ts", "common/replay-headless/src/**/__snapshots__/**", "common/replay-headless/src/**/__tests__/**",
	"common/replay-shared/src/**/*.test.ts", "common/replay-shared/src/**/__snapshots__/**", "common/replay-shared/src/**/__tests__/**",
	"nodejs/src/**/_tests/**",
	"nodejs/src/ingestion/pipelines/sessionreplay/ml-mirror-image-scrub-sidecar/**",
]

_baseData: [
	"frontend/src/products.json", "products/canvas/packages/canvas_builder/manifest.json",
	"products/notebooks/notebook-widget-catalog.json", "products/ai_observability/shared/**",
	"products/dashboards/backend/api/dashboard_template_schema.json",
	"products/demo/backend/logic/dashboard_template_seeds/**",
	"products/growth/backend/enrichment/*.hog", "products/signals/skills/*/references/*.json",
	"services/mcp/schema/tool-definitions-all.json", "common/plugin_transpiler/src/**",
	"common/plugin_transpiler/{package.json,build.mjs,tsconfig.json}",
]

_python_core_paths: [
	"packages/owners-yaml/owners_yaml/**/*.py",
	"tools/hogli-commands/hogli_commands/**/*.py",
	"tools/hogli/src/**/*.py",
]

_py_cone: list.Concat([_djangoTree, [
	".depot/workflows", ".github/new-events-schema-targets.txt", ".github/workflows/ci-python.yml",
	".semgrep/rules/devex", ".stamphog", "docker/clickhouse/user_defined_function.xml",
	"frontend/src/taxonomy/core-filter-definitions-by-group.json", "livestream/bot",
	"rust/feature-flags/src/properties", "rust/feature-flags/tests/fixtures",
	"services/hogql-language-service/internal/completion", "services/mcp/schema", "services/mcp/src/templates",
]])

_python_monolith_include: list.Concat([_djangoTree, [
	".dagster_home", ".depot/workflows", ".github/new-events-schema-targets.txt",
	".github/scripts", ".github/workflows/ci-python.yml",
	".semgrep/rules/devex", ".semgrep/rules/security", ".stamphog", "AGENTS.md", "docker",
	"docker-compose.base.yml", "docker-compose.dev.yml", "docker-compose.profiles.yml",
	"frontend/src/lib/agentScopes.generated.ts",
	"frontend/src/lib/components/AgentObjectTags/objectKinds.generated.ts",
	"frontend/src/lib/components/DomainConnect/templates",
	"frontend/src/products.json", "frontend/src/queries/schema.json",
	"frontend/src/taxonomy/core-filter-definitions-by-group.json",
	"infra", "livestream/bot",
	"packages/agent/packages/agent-contracts/src/model-catalog.generated.ts",
	"packages/agent/packages/agent-contracts/src/objectTagKinds.generated.ts",
	"packages/agent/packages/agent/src/utils/gateway-routing-cases.json",
	"rust/common/ingestion_warnings/warning_types.generated.json",
	"rust/feature-flags/src/properties", "rust/feature-flags/tests/fixtures",
	"rust/persons_migrations",
	"services/hogql-language-service/internal/completion",
	"services/mcp/schema", "services/mcp/scripts/build-cli-agent-scopes.ts",
	"services/mcp/scripts/generate-ui-apps.ts",
	"services/mcp/src/lib/oauth-scopes.generated.ts",
	"services/mcp/src/lib/trace-property-allowlist.generated.ts",
	"services/mcp/src/resources/ui-apps.generated.ts", "services/mcp/src/templates",
	"services/stripe-mock/tests/conftest.py",
]])

_storybookConfig: [
	"common/storybook/*",
	"common/storybook/.storybook/{README.md,app-context.ts,main.ts,preview.tsx,test-runner.ts}",
	"common/storybook/.storybook/{decorators,public}/**",
	"common/storybook/.storybook/plugins/vite-{frontend-resolve,module-graph,sql-raw}-plugin.ts",
]

_tsgoCache: ".enact/state/tsgo"

_rustCrates: ["rust/*/**/Cargo.toml"]
_rustCrateRules: [
	{
		match: [
			"showcase/scripts/run_rust_tests.sh", "showcase/scripts/rust_footprint.py",
			"showcase/scripts/rust_nextest.toml", "infra/**", "docker/**",
			"showcase/scripts/{test_databases.sh,template_inputs.py,template_publications.py,create_test_kafka_topics.py,seaweedfs_setup.sh}",
			"showcase/scripts/tests/**", "showcase/.gitignore",
		]
		action: "ignore"
	},
	{
		match: list.Concat([[
			"rust/**", "proto/**", "posthog/api/feature_flag.py",
			"posthog/models/feature_flag/flags_cache.py", "posthog/models/feature_flag/feature_flag.py",
		], _rustEveryCrate])
		command: "showcase/scripts/rust_affected_crates.sh {changed_files}"
	},
]

_productsFrontendBin: ["products/*/frontend/bin/**"]
_djangoTree: ["posthog", "ee", "products", "common", "bin", "tools/hogli-commands", "tools/hogli", "packages/owners-yaml", "packages/personhog-proto"]
_mcpPrebuild: "../../showcase/scripts/build_mcp_ui_apps.sh && pnpm exec tsx scripts/copy-instructions.ts"
_frontendBuild: "showcase/scripts/build_once.sh frontend-build frontend/dist/.enact-build-key frontend products common packages ee/frontend services/mcp/src/ui-apps package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json tsconfig.json patches -- bash -c 'showcase/scripts/build_quill.sh && showcase/scripts/build_hogvm.sh && bin/turbo --filter=@posthog/frontend prepare && showcase/scripts/build_products.sh && pnpm --filter=@posthog/frontend build'"

_buildOnceKey: [
	"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "turbo.json", "tsconfig.json",
	"patches/**", "showcase/scripts/build_once.sh", "showcase/scripts/exclusive.sh", "showcase/scripts/build_quill.sh",
]

_mcpUiAppsNeeds: ["mcp:ui_apps", "quill:build"]
_mcpUiAppsFiles: [
	"services/mcp/src/ui-apps/**", "services/mcp/src/resources/ui-apps.generated.ts",
	"services/mcp/vite.ui-apps.config.ts", "services/mcp/scripts/build-ui-apps.ts",
	"services/mcp/scripts/generate-ui-apps.ts", "services/mcp/scripts/post-ui-apps-size-section.mjs",
	"services/mcp/scripts/yaml-config-schema.ts", "products/*/mcp/**",
	"services/mcp/definitions/*.yaml", "common/mosaic/**", "packages/quill/**",
	"products/product_analytics/frontend/insights/**", "products/*/frontend/generated/**",
	"showcase/scripts/check_mcp_ui_apps.sh", "showcase/scripts/build_mcp_ui_apps.sh",
]

_pytestFiles:  ["test_*.py", "*_test.py"]
_pytestErrors: [2, 3, 4]
// The services test_databases.sh's per-worker setup uses before any test (psql,
// clickhouse-client, create_test_kafka_topics.py's librdkafka): no test footprint names them.
_pytestSetupServices: ["postgres", "clickhouse", "kafka"]

_harness: {
	root:       "."
	depends_on: [...string] | *["root"]
}

_pytestRunTask: {
	command:          string | *"bash showcase/scripts/run_sharded_pytest.sh {targets}"
	timeout:          "90m"
	error_exit_codes: _pytestErrors
	services:         _pytestSetupServices
}

_djangoSuite: {
	kind:       "service"
	domain:     "analytics"
	technology: "python"
	root:       "."
	fmt: {
		command: "uv run --no-sync ruff format --check {changed_files}"
		filter:  include: ["**/*.py"]
	}
	lint: {
		command: "uv run --no-sync ruff check {changed_files}"
		filter:  include: ["**/*.py"]
	}
	recorder: "own"
	target_scope: fallback: "none"
}

_mcpVitestJob: {
	recorder:    "trace"
	recorded_by: ["enact-node"]
	needs:       _mcpUiAppsNeeds
}

_rustTestScopeRules: [
	{match: ["rust/**"], engine: "reach"},
	{match: ["showcase/scripts/{run_rust_release_build.sh,rust_affected_crates.sh}"], action: "ignore"},
]

pipeline: schema.#Pipeline & {
	name:        "posthog-platform"
	description: "PostHog Analytics Platform: Accelerated CI/CD Pipeline (enact + enve)"
	env: {}
	workspace_scope: {
		include: [
			"enve.cue", "enve.lock", ".enact", "cue.mod", "showcase", "patches",
			"tools/hogli", "packages/owners-yaml", "packages/personhog-proto",
			"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "turbo.json",
			"tsconfig.json", "tsconfig.dev.json", "tsconfig.kea-typegen.json",
			".oxfmtrc.json", ".oxlintrc.json", ".prettierignore", ".stylelintrc.js",
			".stylelintignore", ".nvmrc", ".kearc", "postcss.config.js",
			"pyproject.toml", "uv.lock", "conftest.py", "pytest.ini", "pytest_boot_gc.py",
			".test_quarantine.json", "manage.py", "hogli.yaml", "posthog.json",
			"owners.yaml", "tach.toml", "depot.json", "dist-workspace.toml", "dagster_cloud.yaml",
		]
		ignore: [
			"**/*.md", "**/*.mdx", "**/LICENSE", "**/.env.*", "**/.gitignore", "**/.dockerignore",
			"compose.yaml", "**/docker-compose*.yml", "otel-collector-config.dev.yaml",
			".agents/**", "**/.claude/**", ".codex/**", ".cursor/**", ".cursorignore", ".cursorrules",
			".posthog-code/**", ".mcp.json", ".coderabbit.yaml", "**/.greptile/**",
			".interface-design/**", ".config/**", "**/.editorconfig", ".envrc", ".easignore",
			".flox/**", ".git-blame-ignore-revs", ".github/ISSUE_TEMPLATE/**", ".husky/**",
			".idea/**", ".run/**", ".trunk/**", "**/.vscode/**", ".watchmanconfig",
			".worktreeinclude", ".worktreelink", ".zed/**",
		]
	}
	triggers: {
		pull_request: {branches: ["master", "main", "perf/ci-modernization", "perf/ci-showcase"], paths: []}
		push:         {branches: ["master", "main", "perf/ci-modernization", "perf/ci-showcase"], paths: ["**/*"]}
		schedule:     []
	}
	components: {
		"root": {
			name:        "root"
			title:       "Environment & pipeline"
			root:        "."
			watch_paths: ["enve.cue", "enve.lock", ".enact/*", "cue.mod/**", ".github/workflows/ci.yml", "showcase/scripts/exclusive.sh", "bin/linux-x86_64/**", "bin/linux-aarch64/**", "bin/macos-aarch64/**", "bin/enact", "bin/enve"]
		}
		"build_once": _harness & {
			name: "build_once", title: "Build-once helper", technology: ["python", "typescript"]
			watch_paths: ["showcase/scripts/build_once.sh"]
		}
		"vitest_marker": _harness & {
			name: "vitest_marker", title: "vitest runner and recorder marker"
			watch_paths: [".enact/vitest/**"]
		}
		"js-root": _harness & {
			name: "js-root", title: "pnpm workspace root", technology: "typescript"
			watch_paths: [
				"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "turbo.json",
				"tsconfig.json", "tsconfig.*.json", ".oxfmtrc.json", ".oxlintrc.json",
				".prettierignore", ".stylelintrc.js", ".stylelintignore", ".nvmrc", "patches/**",
			]
		}
		"test_quarantine": _harness & {
			name: "test_quarantine", title: "Test quarantine", technology: ["python", "typescript"]
			watch_paths: [".test_quarantine.json", "frontend/jest.quarantine.ts", ".github/scripts/jest-retries.cjs"]
		}
		"py-root": _harness & {
			name: "py-root", title: "uv project root", technology: "python", depends_on: ["root", "test_quarantine"]
			workspace_scope: include: _py_cone
			watch_paths: ["pyproject.toml", "uv.lock", "conftest.py", "pytest.ini", "pytest_boot_gc.py", "showcase/scripts/setup.sh", "showcase/scripts/backend_runtime.py"]
		}
		"pytest_plugins": _harness & {
			name: "pytest_plugins", title: "pytest plugins", technology: "python"
			depends_on: ["py-root"], watch_paths: ["showcase/pytest_plugins/**"]
		}
		"pytest_runner": _harness & {
			name: "pytest_runner", title: "pytest runner", technology: "python"
			depends_on: ["py-root", "pytest_plugins", "test_env", "geoip"]
			watch_paths: ["showcase/scripts/run_sharded_pytest.sh", "showcase/scripts/product_pytest.py"]
		}
		"test_env": _harness & {
			name: "test_env", title: "Shared test databases & services"
			description: "Service configuration and the helpers forking and seeding test databases"
			technology: "python", workspace_scope: include: ["infra", "docker"]
			watch_paths: [
				"infra/clickhouse/config.xml", "infra/clickhouse/start.sh",
				"infra/clickhouse/users.d/**", "infra/clickhouse/build_host_udfs.sh",
				"docker/**", "showcase/scripts/test_databases.sh", "rust/persons_migrations/**",
				"showcase/scripts/template_inputs.py", "showcase/scripts/template_publications.py",
				"showcase/scripts/create_test_kafka_topics.py", "showcase/scripts/seaweedfs_setup.sh", "showcase/.gitignore",
			]
		}
		"geoip": _harness & {
			name: "geoip", title: "GeoIP database installer"
			watch_paths: ["bin/download-mmdb"]
		}
		"helper_tests": {
			name:            "helper_tests"
			title:           "Overlay helpers' tests"
			description:     "The unittest suite of the overlay's scripts: shard provisioning, runners, templates"
			technology:      "python"
			root:            "."
			depends_on:      ["test_env", "py-root", "pytest_plugins", "pytest_runner", "build_once"]
			workspace_scope: include: [".github/workflows/ci.yml"]
			watch_paths: [
				"showcase/scripts/tests/**", "showcase/scripts/run_nodejs_tests.sh",
				"showcase/scripts/rust_footprint.py", "showcase/scripts/run_rust_release_build.sh",
				"showcase/scripts/live_footprint.py", "showcase/scripts/node_reads.mjs",
				"showcase/scripts/no_drift.sh", "posthog/user_scripts/**",
				"packages/personhog-proto/pyproject.toml", "packages/owners-yaml/pyproject.toml", "tools/hogli/pyproject.toml",
			]
			test:             "uv run --no-sync python -m unittest {targets}"
			recorder:         "trace"
			record_resources: _recordPy
			target_scope: {
				tests:          ["showcase/scripts/tests/test_*.py"]
				default_target: "discover -s showcase/scripts/tests -t showcase/scripts/tests"
			}
		}
		"base": _djangoSuite & {
			name:        "base"
			title:       "PostHog Core Django API & Analytics Backend"
			description: "Django ASGI server, models, HogQL, REST endpoints and ClickHouse queries"
			depends_on:  ["py-root", "pytest_plugins", "pytest_runner", "test_env", "build_once"]
			tags:        ["backend", "django", "api"]
			// ee/hogai/test/test_llm.py reads the settings scene's ids (SETTINGS_MAP_PATH).
			workspace_scope: {include_dependencies: false, include: list.Concat([_python_monolith_include, ["frontend/src/scenes/settings/SettingsMap.tsx"]])}
			watch_paths: list.Concat([[
				"posthog/[!d]*/**", "posthog/d[!a]*/**", "posthog/*", "ee/**", "manage.py", "common/__init__.py",
				"common/hogql_parser/**", "common/migration_utils/**",
				"common/fixtures/**", "common/ingestion/**",
				"packages/personhog-proto/**", "products/db_routing.yaml",
				"common/hogvm/__init__.py", "common/hogvm/python/**",
				"packages/owners-yaml/owners_yaml/**",
				"tools/hogli-commands/hogli_commands/{__init__,change_detection,projections}.py",
				"tools/hogli-commands/hogli_commands/{quarantine,product}/**",
				"tools/hogli/src/hogli/{__init__,manifest}.py",
				"products/**/*.py", ".semgrep/**",
				"showcase/scripts/build_plugin_transpiler.sh",
				"showcase/scripts/fetch_test_durations.sh",
				"showcase/scripts/repo_invariants.sh",
			], _baseData])
			fmt: filter: exclude:  ["products/**"]
			lint: filter: exclude: ["products/**"]
			max_shards: 12
			shards:     4
			jobs: {
				audit: {
					name:      "Audit"
					direct:    true
					services:  false
					resources: {cpus: 4.0, memory_mb: 8192}
					tasks: [{command: "PYTEST_NUM_WORKERS=$ENACT_SHARD_WORKERS ./showcase/scripts/repo_invariants.sh"}]
				}
				migrate: {
					name:     "Migrate"
					services: false
					tasks: [{
						name:    "Check Migrations"
						command: "uv run --no-sync python manage.py makemigrations --check --dry-run"
						filter: include: ["**/*.py"]
					}]
				}
				test: {
					name: "Test"
					// Nightly peaks per shard: 1.8-3.8 GB (a 10.9 GB shard was the warehouse-URL hook's
					// absence: test_groups_revenue_analytics' s3() reads retried at upstream's bucket).
					resources: {cpus: 0.75, memory_mb: 4096}
					tasks: [
						{name: "Build plugin transpiler", command: "showcase/scripts/build_plugin_transpiler.sh", timeout: "15m"},
						_pytestRunTask & {name: "Run Tests"},
					]
				}
			}
			scoping: {
				domain_roots:    ["posthog", "ee", "products"]
				service_markers: ["django_db", "BaseTest", "APITestCase", "ClickhouseTestMixin", "NonDeterministicDatabaseTestMixin", "posthog.test"]
			}
			target_scope: {
				rules: [
					{match: ["posthog/dags/**", "products/*/dags/**"], action: "ignore"},
					{
						match: list.Concat([[
							"posthog/**/*.{py,ambr}", "ee/**/*.{py,ambr}", "common/**/*.py",
							"packages/personhog-proto/**/*.py", "products/**/*.py",
						], _python_core_paths])
						engine:      "python"
						granularity: "file"
					},
					{match: _baseData, engine: "reach"},
					{match: [".semgrep/**"], action: "ignore"},
				]
				tests:   [for root in ["posthog", "ee"] for f in _pytestFiles {"\(root)/**/\(f)"}]
				exclude: ["posthog/user_scripts/**", "posthog/dags/**", "posthog/api/test/rust_integration/**"]
				arch_exclusions: [{
					arch:   "x86_64"
					tests:  ["posthog/cdp/templates/reddit/**"]
					reason: "STPyV8 has no linux aarch64 wheel (usecases/posthog/LEARNINGS.md, platform row): the reddit pixel templates need x86_64"
				}]
			}
			uses: _backendServices
		}
		"products": _djangoSuite & {
			name:            "products"
			title:           "PostHog Product Backends"
			description:     "Each product's Django app, Dagster assets and evaluation harnesses"
			depends_on:      ["base", "py-root", "test_env"]
			// messaging's test_message_preference_styles reads the compiled stylesheet (STYLESHEET).
			workspace_scope: {include_dependencies: false, include: list.Concat([_python_monolith_include, ["frontend/public/message-preferences.css"]])}
			tags:            ["backend", "django", "products"]
			watch_paths: [
				"products/*.py", "products/ruff.toml", "products/*/*.py", "products/*/backend/**",
				"products/*/{dags,eval,evals,eval_harness,stats,fixtures,management,opensearch,observability,plan,adr,shared,scout,agent}/**",
				"products/{data_catalog,posthog_ai,support,tasks,web_analytics}/scripts/**",
				"products/stamphog/packages/**", "packages/agent/agent-shadow/**",
				".stamphog/**", "dagster_cloud.yaml", ".dagster_home/**",
			]
			jobs: typecheck: {
				direct:    true
				services:  false
				worker:    "standard"
				resources: {cpus: 2.0, memory_mb: 11264}
				tasks: [{
					command: "uv run --no-sync ty check posthog ee common products && uv run --no-sync mypy --cache-fine-grained posthog ee common products services/stripe-mock/tests/conftest.py"
					env: MYPY_NUM_WORKERS: "2"
					filter:  {include: ["**/*.py", "**/*.pyi"], on_empty: "run_all"}
					timeout: "30m"
				}]
			}
			max_shards:   12
			shards:       4
			shard_groups: {by: "products/*/", overhead_s: 17}
			// The nightly's measured shard peak: 7.1 GB (warehouse_sources' shard).
			resources: {cpus: 0.75, memory_mb: 7680}
			scoping: {
				domain_roots:    ["posthog", "ee", "products"]
				service_markers: ["django_db", "BaseTest", "APITestCase", "ClickhouseTestMixin", "NonDeterministicDatabaseTestMixin", "posthog.test"]
			}
			target_scope: {
				rules: [
					{match: ["posthog/dags/**", "products/*/dags/**"], action: "ignore"},
					{
						match: list.Concat([[
							"products/*.py", "products/*/*.py", "products/*/backend/**/*.{py,ambr}",
							"products/*/{dags,eval,evals,eval_harness,stats,management,opensearch,observability,shared,scout,agent,scripts,packages}/**/*.py",
							"posthog/**/*.py", "ee/**/*.py", "common/**/*.py",
						], _python_core_paths])
						engine:      "python"
						granularity: "file"
					},
					{
						match:  list.Concat([_baseData, ["packages/agent/agent-shadow/**"]])
						engine: "reach"
					},
				]
				tests: [for f in _pytestFiles {"products/*/backend/**/\(f)"}]
			}
			test: _pytestRunTask & {
				command: "showcase/scripts/build_once.sh canvas-builder-deps products/canvas/packages/canvas_builder/node_modules/.enact-build-key products/canvas/packages/canvas_builder/package.json products/canvas/packages/canvas_builder/package-lock.json -- npm ci --ignore-scripts --omit=dev --no-audit --no-fund --prefix products/canvas/packages/canvas_builder && bash showcase/scripts/run_sharded_pytest.sh {targets}"
			}
			uses: _backendServices
		}
		"dagster": _djangoSuite & {
			name:            "dagster"
			title:           "Dagster jobs"
			description:     "Dagster assets and jobs of core and the products"
			depends_on:      ["base", "products", "py-root", "test_env"]
			workspace_scope: {include_dependencies: false, include: _python_monolith_include}
			watch_paths:     ["posthog/dags/**", "products/*/dags/**", "dagster_cloud.yaml", ".dagster_home/**"]
			jobs: typecheck: {
				direct:    true
				services:  false
				resources: {cpus: 2.0, memory_mb: 4096}
				tasks: [{
					command: "uv run --no-sync ty check {changed_files} && uv run --no-sync mypy {changed_files}"
					filter:  include: ["posthog/dags/**/*.py", "posthog/dags/**/*.pyi"]
					timeout: "15m"
				}]
			}
			shards:            3
			service_instances: "per_shard"
			resources:         {cpus: 2.0, memory_mb: 5120}
			scoping: {
				domain_roots:    ["posthog", "products"]
				service_markers: ["django_db", "BaseTest", "ClickhouseTestMixin", "posthog.test"]
			}
			target_scope: {
				rules: [{
					match: [
						"posthog/**/*.{py,ambr}", "ee/**/*.py", "common/**/*.py",
						"packages/personhog-proto/**/*.py", "products/**/*.{py,ambr}",
					]
					engine: "python"
				}]
				tests: [for root in ["posthog/dags", "products/*/dags"] for f in _pytestFiles {"\(root)/**/\(f)"}]
			}
			record_resources: resources
			test:             _pytestRunTask
			uses: [
				{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres, title: "Reads & writes app metadata"},
				{protocol: schema.#Protocol.Redis, target: pipeline.services.redis, title: "Caches sessions & flags"},
				{protocol: schema.#Protocol.Http, target: pipeline.services.clickhouse, title: "Analytics DBMS"},
				{protocol: schema.#Protocol.Http, target: pipeline.services.seaweedfs, title: "Object storage for staging & recordings"},
			]
		}
		"product_structure": {
			name:       "product_structure"
			title:      "Product structure and isolation"
			technology: "python"
			root:       "."
			depends_on: ["py-root"]
			watch_paths: [
				"products/**/*.py", "posthog/**/*.py", "ee/**/*.py", "common/**/*.py",
				"products/*/product.yaml", "products/isolation_baseline.txt",
				"products/model_crossing_uses_baseline.txt", "tach.toml", ".importlinter",
			]
			lint: "uvx tach check --dependencies --exclude 'tests,test,**/test_*.py,**/*_test.py' && uvx tach check --interfaces"
		}
		"openapi_types": {
			name:            "openapi_types"
			title:           "Generated OpenAPI types"
			technology:      "python"
			root:            "."
			depends_on:      ["base", "products"]
			workspace_scope: {include_dependencies: false, include: list.Concat([_py_cone, ["tools/openapi-codegen", "frontend/bin", "frontend/src/generated", "frontend/src/lib/api-orval-mutator.ts", "frontend/src/lib/agentScopes.generated.ts", "services/mcp/definitions", "services/mcp/scripts", "services/mcp/src"]])}
			watch_paths: [
				"frontend/src/generated/**", "frontend/src/lib/agentScopes.generated.ts",
				"products/*/frontend/generated/**", "services/mcp/src/generated/**",
				"services/mcp/src/api/generated.ts", "tools/openapi-codegen/**",
				"services/mcp/scripts/**", "frontend/bin/generate-openapi-types.mjs",
				"products/dashboards/frontend/bin/generate-widget-config-zod.mjs",
				"frontend/src/lib/api-orval-mutator.ts", "services/mcp/definitions/**/*.yaml",
				"products/*/mcp/**/*.yaml", "services/mcp/schema/tool-definitions.json",
				"services/mcp/schema/tool-definitions-v2.json", "services/mcp/src/tools/generated/**",
				"services/mcp/schema/generated-tool-definitions.json",
				"services/mcp/schema/tool-definitions-all.json",
				"services/mcp/src/templates/sections/**",
				"services/mcp/schema/exec-command-reference.md",
				"showcase/scripts/no_drift.sh",
			]
			schema_check: {
				command:         "./bin/hogli build:openapi && pnpm --filter=@posthog/mcp run scaffold-yaml -- --sync-all"
				expect_no_drift: true
			}
			resources: {cpus: 1.0, memory_mb: 2400}
		}
		"frontend": {
			name:        "frontend"
			title:       "PostHog Frontend Web Application"
			description: "React, Vite, Kea state logics, scenes, and visual regression tests"
			kind:        "app"
			domain:      "web"
			uses:        [{protocol: schema.#Protocol.Http, target: "base", title: "Queries Django REST & HogQL endpoints"}]
			technology:  "typescript"
			root:        "."
			depends_on:  ["js-root", "quill", "test_quarantine"]
			tags:        ["frontend", "vite", "react", "kea"]
			workspace_scope: {
				// jest.config's setupFilesAfterEnv names .github/scripts/jest-retries.cjs.
				include: ["frontend", "products", "packages", "common", "docs/onboarding", "playwright", "services/mcp", ".github/scripts/jest-retries.cjs", "posthog/hogql_queries/utils/breakdowns.py"]
				ignore:  _productsFrontendBin
			}
			watch_paths: list.Concat([[
				"frontend/**", "products/*/frontend/**", "products/*/*.{ts,tsx,json}",
				"products/games/**", "products/canvas/packages/**", "products/visual_review/cli/**",
				"docs/onboarding/**", "common/esbuilder/**", "common/tailwind/**",
				"common/replay-shared/**", "common/hogvm/typescript/src/**",
				"common/hogvm/typescript/package.json", "packages/llm-normalizer/src/**",
				"packages/llm-normalizer/package.json", "products/ai_observability/shared/**",
				".kearc", "posthog.json", "postcss.config.js",
				"showcase/scripts/build_products.sh", "bin/validate-setup-tasks.mjs",
			], _storybookConfig])
			fmt:       "pnpm exec oxfmt --check --no-error-on-unmatched-pattern {changed_files}"
			lint:      "pnpm exec oxlint --no-error-on-unmatched-pattern {changed_files} --quiet"
			resources: {cpus: 2.0, memory_mb: 5120}
			scoping: domain_roots: ["frontend/src", "products", "common", "packages"]
			jobs: {
				build: {
					services:  false
					builds:    true
					worker:    "standard"
					resources: {cpus: 4.0, memory_mb: 10240}
					outputs: {
						paths: ["frontend/dist"]
						key: list.Concat([[
							"frontend/**", "products/**", "common/**", "packages/**",
							"ee/frontend/**", "services/mcp/src/ui-apps/**",
							"showcase/scripts/build_hogvm.sh", "showcase/scripts/build_products.sh",
						], _buildOnceKey])
					}
					needs: ["quill:build"]
					tasks: [{command: _frontendBuild, env: GOMEMLIMIT: "6GiB"}]
				}
				typecheck: {
					direct:    true
					worker:    "standard"
					resources: {cpus: 2.0, memory_mb: 12288}
					needs:     ["quill:build"]
					tasks: [
						{
							name:            "Build products"
							command:         "showcase/scripts/build_quill.sh && showcase/scripts/build_hogvm.sh && pnpm exec turbo --filter=@posthog/frontend prepare && showcase/scripts/build_products.sh && git diff --exit-code -- frontend/src/products.tsx frontend/src/products.json"
							expect_no_drift: ["frontend/src/products.tsx", "frontend/src/products.json"]
						},
						{
							name:    "Kea typegen"
							command: "frontend/node_modules/.bin/kea-typegen write --delete --show-ts-errors"
							env: NODE_OPTIONS: "--max-old-space-size=8192"
						},
						{
							name:    "tsgo"
							command: "pnpm --filter=@posthog/frontend exec tsgo --noEmit false --emitDeclarationOnly --outDir ../\(_tsgoCache)/out --rootDir .. --tsBuildInfoFile ../\(_tsgoCache)/frontend.tsbuildinfo --checkers 1"
							env: GOMEMLIMIT: "10GiB"
							timeout: "20m"
						},
						{
							name:            "Schema drift"
							command:         "pnpm --filter=@posthog/frontend schema:build:json && git diff --exit-code -- frontend/src/queries/schema.json frontend/src/queries/validators.js && NODE_OPTIONS=--max-old-space-size=8192 pnpm --filter=@posthog/frontend mobile-replay:schema:build:json && git diff --exit-code -- frontend/src/scenes/session-recordings/mobile-replay/schema/web/rr-web-schema.json frontend/src/scenes/session-recordings/mobile-replay/schema/mobile/rr-mobile-schema.json"
							expect_no_drift: ["frontend/src/queries/schema.json", "frontend/src/queries/validators.js", "frontend/src/scenes/session-recordings/mobile-replay/schema/web/rr-web-schema.json", "frontend/src/scenes/session-recordings/mobile-replay/schema/mobile/rr-mobile-schema.json"]
							filter: include: [
								"**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts}", "**/tsconfig*.json", "**/package.json",
								"frontend/src/queries/schema.json", "frontend/src/scenes/session-recordings/mobile-replay/schema/**",
							]
						},
						{
							name:    "App URL manifest"
							command: "pnpm --filter=@posthog/frontend build:app-urls:check"
							filter: include: [
								"frontend/bin/build-app-url-manifest.mjs", "frontend/src/scenes/urls.ts",
								"products/*/manifest.tsx", "services/mcp/src/tools/links/app-url-manifest.json",
							]
						},
						{
							name:    "Setup tasks"
							command: "node bin/validate-setup-tasks.mjs"
							filter: include: [
								"bin/validate-setup-tasks.mjs", "frontend/src/generated/core/api.schemas.ts",
								"frontend/src/lib/components/ProductSetup/productSetupRegistry.ts",
							]
						},
					]
				}
				test: {
					name:        "Test"
					shards:      4
					worker:      "standard"
					resources:   {cpus: 2.0, memory_mb: 5120}
					recorder:    "trace"
					recorded_by: ["enact-node"]
					tasks: [
						{name: "Build products", command: "showcase/scripts/build_products.sh"},
						{name: "Warm jest", command: "CI=true pnpm --filter=@posthog/frontend exec jest --listTests >/dev/null"},
						// ENACT_TEST_VERBOSE: each test's line (`✓`/`✕`), which enact reads into per-test outcomes.
						{name: "Run Tests", command: "CI=true pnpm --filter=@posthog/frontend exec jest --maxWorkers=2 --forceExit --testNamePattern='^(?!evaluationBackfillsLogic anchors a relative preset on the project timezone$)' ${ENACT_TEST_VERBOSE:+--verbose} {targets}"},
					]
				}
			}
			target_scope: {
				fallback: "none"
				rules: [
					{
						match: [
							"frontend/**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts,snap}",
							"products/*/frontend/**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts,snap}",
							"products/*/*.{ts,tsx}", "products/games/**/*.{ts,tsx}",
							"docs/onboarding/**/*.{ts,tsx}",
							"common/{esbuilder,hogql_parser,hogvm,plugin_transpiler,replay-headless,replay-shared,tailwind}/**/*.{ts,tsx,js,jsx,mjs,cjs}",
							"common/storybook/*.{ts,tsx,js,jsx,mjs,cjs}",
							"common/storybook/.storybook/{app-context.ts,main.ts,preview.tsx,test-runner.ts}",
							"common/storybook/.storybook/{decorators,public}/**/*.{ts,tsx,js,jsx,mjs,cjs}",
							"common/storybook/.storybook/plugins/vite-{frontend-resolve,module-graph,sql-raw}-plugin.ts",
							"packages/llm-normalizer/src/**/*.ts",
						]
						engine:      "typescript"
						granularity: "file"
					},
					{
						match:  ["packages/llm-normalizer/src/**/*.yaml", "products/ai_observability/shared/**", "common/hogvm/typescript/**"]
						engine: "reach"
					},
					{
						match:  ["frontend/**/*.{css,less,scss,svg,png}", "products/*/frontend/**/*.{css,less,scss,svg,png}", "frontend/snapshots.yml"]
						action: "ignore"
					},
				]
				tests: ["frontend/**/*.test.{ts,tsx,js,jsx}", "products/*/frontend/**/*.test.{ts,tsx,js,jsx}"]
				not_run: [{
					tests:  ["products/ai_observability/frontend/evaluations/evaluationBackfillsLogic.test.ts::evaluationBackfillsLogic anchors a relative preset on the project timezone"]
					reason: "upstream test subtracts 7 days from startOf('day') across the US fall-back DST transition without re-anchoring the pre-transition offset"
				}]
			}
		}
		"quill": {
			name:        "quill"
			title:       "PostHog Quill UI & Design System"
			description: "Reusable UI primitives, buttons, badges, and chart components"
			kind:        "library"
			domain:      "web"
			technology:  "typescript"
			root:        "packages/quill"
			depends_on:  ["js-root", "build_once"]
			tags:        ["design-system", "frontend", "tokens"]
			watch_paths: ["packages/quill/**", "showcase/scripts/build_quill.sh"]
			jobs: build: {
				services: false
				builds:   true
				outputs: {
					paths: [
						"packages/quill/packages/quill/dist", "packages/quill/packages/tokens/dist",
						"packages/quill/packages/primitives/dist", "packages/quill/packages/components/dist",
						"packages/quill/packages/charts/dist", "packages/quill/packages/blocks/dist",
						"packages/quill/packages/quill/dist/.enact-build-key",
					]
					key:   list.Concat([["packages/quill/**"], _buildOnceKey])
				}
				tasks: [{command: "rm -f packages/quill/dist/.enact-build-key && ../../showcase/scripts/build_quill.sh"}]
			}
			lint: {
				dir:     "."
				command: "pnpm exec oxlint --no-error-on-unmatched-pattern {changed_files} --quiet"
			}
		}
		"agent": {
			name:        "agent"
			title:       "PostHog Agent Runtime & SDKs"
			description: "PostHog agent runtime and the packages it bundles"
			kind:        "library"
			domain:      "ai"
			technology:  "typescript"
			root:        "packages/agent"
			depends_on:  ["root", "build_once", "vitest_marker"]
			build: {
				lock:    "agent-node-modules"
				command: "pnpm install --frozen-lockfile && pnpm run build"
			}
			jobs: test: {
				name:        "Test"
				shards:      1
				recorder:    "trace"
				recorded_by: ["enact-node"]
				tasks: [
					{
						name: "Build"
						dir:  "."
						lock: "agent-node-modules"
						once: {
							key:     "agent-node-modules"
							inputs:  ["packages/agent/package.json", "packages/agent/pnpm-lock.yaml", "packages/agent/pnpm-workspace.yaml", "packages/agent/packages/*/package.json"]
							outputs: ["packages/agent/node_modules"]
						}
						command: "showcase/scripts/build_once.sh agent-node-modules packages/agent/node_modules/.enact-build-key packages/agent/package.json packages/agent/pnpm-lock.yaml packages/agent/pnpm-workspace.yaml 'packages/agent/packages/*/package.json' -- pnpm --dir packages/agent install --frozen-lockfile && cd packages/agent && pnpm exec turbo run build --filter='!@posthog/agent'"
					},
					{name: "Run Tests", command: "../../showcase/scripts/agent_vitest.sh {relative_targets}"},
				]
			}
			watch_paths:  ["showcase/scripts/agent_vitest.sh"]
			target_scope: tests: ["packages/agent/packages/*/src/**/*.test.ts"]
		}
		"rust_services": {
			name:            "rust_services"
			title:           "PostHog Rust Microservices (Capture & Feature Flags)"
			kind:            "service"
			domain:          "ingestion"
			technology:      ["rust", "python"]
			root:            "rust"
			depends_on:      ["test_env", "proto", "geoip"]
			// affected-services' integration tests parse the image list (load_test_fixtures).
			workspace_scope: include: list.Concat([_djangoTree, ["rust", "proto", "docker", "infra", ".github/rust-images.yml"]])
			watch_paths: list.Concat([[
				"rust/**", "posthog/api/feature_flag.py",
				"posthog/models/feature_flag/flags_cache.py", "posthog/models/feature_flag/feature_flag.py",
				"showcase/scripts/run_rust_tests.sh", "showcase/scripts/rust_footprint.py",
				"showcase/scripts/rust_ci_env.sh", "showcase/scripts/rust_nextest.toml",
				"showcase/scripts/{run_rust_release_build.sh,rust_affected_crates.sh}", "clippy.toml",
			], _djangoMigrations])
			fmt: "cargo fmt --check"
			jobs: {
				lint: {
					direct:    true
					services:  false
					resources: {cpus: 2.0, memory_mb: 6000}
					target_scope: {
						select_in_job: true
						tests:         _rustCrates
						rules:         list.Concat([[{match: ["clippy.toml"], action: "full_component"}], _rustCrateRules])
					}
					tasks: [{
						command: "set -- {targets}; p=--workspace; case \" $* \" in *Cargo.toml*|'  ') ;; *) p=$(printf -- '-p %s ' \"$@\") ;; esac; cargo clippy --all-targets --all-features $p -- -D warnings && cargo shear"
						env: {
							OPENSSL_NO_VENDOR:       "1"
							CARGO_INCREMENTAL:       "0"
							CARGO_PROFILE_DEV_DEBUG: "0"
						}
						timeout: "45m"
					}]
				}
				test: {
					shards:    1
					recorder:  "own_linux"
					resources: {cpus: 4, memory_mb: 8192}
					tasks: [{command: "../showcase/scripts/run_rust_tests.sh {targets}", timeout: "75m"}]
					target_scope: {
						fallback: "none"
						rules:    _rustTestScopeRules
						tests:    [for dir in ["rust/*", "rust/{common,deltalite,hogql}/*"] for f in ["src/lib.rs", "src/main.rs", "src/bin/*.rs", "tests/*.rs"] {"\(dir)/\(f)"}]
						exclude:  _rustIgnoredBinaries
						not_run: [
							{
								tests:  ["rust/common/k8s-awareness/tests/k3s_integration.rs", "rust/kafka-assigner/tests/k3s_integration.rs", "rust/personhog-coordination/tests/k3s_integration.rs"]
								reason: "needs a container runtime (k3s in Docker via testcontainers); services here run rootless under enve, without one"
							},
							{
								tests:  ["rust/feature-flags/src/bin/flags_cache_builder.rs", "rust/feature-flags/src/bin/warm-flags-cache.rs"]
								reason: "built only with its required feature, which ci-rust.yml's test job doesn't enable: cargo builds no test binary of it"
							},
						]
					}
				}
				test_ignored: {
					recorder:         "own_linux"
					resources:        {cpus: 4, memory_mb: 8192}
					record_resources: resources
					tasks: [{command: "../showcase/scripts/run_rust_tests.sh --ignored {targets}", timeout: "45m"}]
					target_scope: {
						fallback: "none"
						rules:    _rustTestScopeRules
						tests:    list.Concat([["rust/cymbal/src/modes/processing/stages/rate_limiting/limiter.rs"], _rustIgnoredBinaries])
					}
				}
				build: {
					shards:    1
					services:  false
					resources: {cpus: 4, memory_mb: 8192}
					tasks: [{command: "../showcase/scripts/run_rust_release_build.sh {targets}", timeout: "90m"}]
					target_scope: {
						select_in_job: true
						tests:         _rustCrates
						rules:         list.Concat([[{match: ["clippy.toml"], action: "ignore"}], _rustCrateRules])
					}
				}
			}
			uses: list.Concat([_ingestionServices, [
				{protocol: schema.#Protocol.Http, target: pipeline.services.seaweedfs},
				{protocol: schema.#Protocol.Http, target: pipeline.services["seaweedfs-open"]},
				{protocol: schema.#Protocol.Grpc, target: pipeline.services.etcd},
				{protocol: schema.#Protocol.Redis, target: pipeline.services["valkey-cluster"]},
			]])
		}
		"hogvm": {
			name:             "hogvm"
			title:            "PostHog Hog VM & Bytecode Compiler"
			kind:             "library"
			domain:           "analytics"
			technology:       ["typescript", "python"]
			root:             "common/hogvm"
			depends_on:       ["py-root", "js-root", "build_once"]
			workspace_scope:  include: ["common/hogvm", "posthog", "bin"]
			watch_paths:      ["common/hogvm/**", "posthog/hogql/**", "bin/hog", "bin/hoge", "showcase/scripts/build_hogvm.sh"]
			test:             "uv run --no-sync pytest {relative_targets}"
			recorder:         "trace"
			record_resources: _recordPy
			target_scope:     tests: ["common/hogvm/python/**/test_*.py"]
			jobs: test_typescript: {
				name:             "Test (TypeScript)"
				recorder:         "trace"
				record_resources: _recordJs
				recorded_by:      ["enact-node"]
				tasks: [
					{name: "Warm jest", command: "pnpm --dir typescript test --listTests --modulePathIgnorePatterns='<rootDir>/[.]turbo(/|$)' >/dev/null"},
					{name: "Run Tests", command: "pnpm --dir typescript test --testNamePattern='^(?!date-like string grammar an ambiguous local time takes the first of the DST fold$)' ${ENACT_TEST_VERBOSE:+--verbose} {relative_targets} --modulePathIgnorePatterns='<rootDir>/[.]turbo(/|$)'"},
				]
				target_scope: {
					tests: ["common/hogvm/typescript/src/**/*.test.ts"]
					not_run: [{
						tests:  ["common/hogvm/typescript/src/__tests__/date.test.ts::date-like string grammar an ambiguous local time takes the first of the DST fold"]
						reason: "upstream luxon 3.5 resolves an ambiguous local time from the zone's current offset, failing while America/New_York is on EST (Nov–Mar)"
					}]
				}
			}
		}
		"livestream": _goModule & {
			name:             "livestream"
			title:            "PostHog Livestream & Realtime Event Gateway"
			kind:             "service"
			domain:           "ingestion"
			root:             "livestream"
			workspace_scope:  include: ["livestream", "products/web_analytics"]
			lint:             _golangciLint
			test:             "../showcase/scripts/run_go_tests.sh --all . {targets}"
			target_scope: not_run: [{
				tests:  ["livestream/*/**/*_test.go"]
				reason: "ci-livestream.yml runs the root package's tests only (`go test -v`): events' TestSessionStats_CleanupEmptyCounters fails on every run (TTL eviction timing)"
			}]
		}
		"proto": {
			name:            "proto"
			title:           "PostHog Protocol Buffers & Schema Definitions"
			kind:            "library"
			domain:          "ingestion"
			technology:      "protobuf"
			root:            "proto"
			depends_on:      ["root"]
			workspace_scope: include: ["bin", "nodejs"]
			watch_paths:     ["proto/**", "packages/personhog-proto/**", "bin/generate_personhog_proto.sh"]
			lint: {
				command:         "buf lint proto/ && buf breaking proto/ --against '../.git#ref=HEAD,subdir=proto' && UV_PROJECT_ENVIRONMENT=.enact/state/proto-venv uv sync --frozen --no-install-project --only-group proto-codegen && PATH=\"$(realpath ../.enact/state/proto-venv)/bin:$PATH\" bash ../bin/generate_personhog_proto.sh && git add -N ../packages/personhog-proto/ && git diff --exit-code -- ../packages/personhog-proto/ && pnpm --dir ../nodejs run generate:personhog-proto && pnpm --dir ../nodejs run generate:ingestion-worker-proto && git add -N ../nodejs/src/common/generated/personhog/ ../nodejs/src/common/generated/ingestion-worker/ && git diff --exit-code -- ../nodejs/src/common/generated/personhog/ ../nodejs/src/common/generated/ingestion-worker/"
				expect_no_drift: ["packages/personhog-proto/**", "nodejs/src/common/generated/personhog/**", "nodejs/src/common/generated/ingestion-worker/**"]
			}
		}
		"workflows": {
			name:       "workflows"
			title:      "GitHub Actions Workflows & Actionlint"
			technology: "yaml"
			root:       "."
			depends_on: ["root"]
			watch_paths: [
				".github/*", ".github/{actions,workflows,pr-deploy}/**",
				".github/scripts/flatten-parallel-steps-for-actionlint.awk",
				".depot/**", "depot.json", "tools/workflow-plan/**", "showcase/scripts/actionlint.sh",
			]
			workspace_scope: include: [".depot", "tools/workflow-plan"]
			lint:            "./showcase/scripts/actionlint.sh"
		}
		"mcp": {
			name:       "mcp"
			title:      "PostHog MCP AI Server & Toolchain"
			kind:       "service"
			domain:     "ai"
			uses:       [{protocol: schema.#Protocol.Http, target: "base", title: "Executes MCP tool calls against PostHog API"}]
			technology: "typescript"
			root:       "services/mcp"
			depends_on: ["js-root", "quill", "vitest_marker"]
			workspace_scope: include: [
				".config", "cli/lib", "common/mosaic", "services/mcp", "packages/llm-normalizer",
				"products", "frontend/src/mocks", "frontend/src/taxonomy", "frontend/bin",
			]
			watch_paths: [
				"services/mcp/**", "products/*/mcp/**", "packages/llm-normalizer/**",
				"packages/quill/**", "common/mosaic/**", ".config/.markdownlint-cli2.jsonc",
				"posthog/[!d]*/**/*.py", "posthog/d[!a]*/**/*.py", "posthog/*.py",
				"ee/**/*.py", "common/**/*.py", "products/*/backend/**/*.py",
				"products/ai_observability/backend/prompts/parser_recipe_examples.yaml",
				"products/*/skills/**",
				"products/{actions,ai_observability,cohorts,error_tracking,experiments,feature_flags,product_analytics,replay,replay_vision,surveys,tasks,tracing,visual_review,workflows}/apps/**",
				"products/notebooks/**", "products/product_analytics/frontend/insights/**",
				"products/*/frontend/generated/**", "frontend/src/mocks/fixtures/**",
				"showcase/scripts/check_mcp_ui_apps.sh", "showcase/scripts/build_mcp_ui_apps.sh",
			]
			fmt:  "pnpm exec oxfmt --check \"./**/*.{md,mdx}\" \"./**/*.{yaml,yml}\""
			lint: "pnpm exec oxlint --quiet . && pnpm exec markdownlint-cli2 --config ../../.config/.markdownlint-cli2.jsonc \"./**/*.{md,mdx}\""
			target_scope: {
				tests:   ["services/mcp/tests/**/*.test.ts"]
				exclude: ["services/mcp/tests/**/*.integration.test.ts", "services/mcp/tests/hono/**"]
				not_run: [{
					tests:  ["services/mcp/tests/live/**"]
					reason: "test:live checks the live context-mill manifest over the network (ci-mcp-live-canary.yml, scheduled)"
				}]
			}
			jobs: {
				test: _mcpVitestJob & {
					name:   "Test"
					shards: 1
					tasks: [
						{name: "Build", command: _mcpPrebuild},
						{name: "Run Tests", command: "../../.enact/vitest/vitest.sh run {relative_targets}"},
					]
				}
				test_hono: _mcpVitestJob & {
					name: "Test (Hono)"
					tasks: [
						{name: "Build", command: _mcpPrebuild},
						{name: "Run Tests", command: "../../.enact/vitest/vitest.sh run --config vitest.hono.config.mts {relative_targets}"},
					]
					target_scope: tests: ["services/mcp/tests/hono/**/*.test.ts"]
				}
				typecheck: {
					direct:    true
					resources: {cpus: 2.0, memory_mb: 4096}
					needs:     _mcpUiAppsNeeds
					tasks: [{command: "../../showcase/scripts/build_mcp_ui_apps.sh && pnpm typecheck"}]
				}
				ui_apps: {
					services:  false
					needs:     ["quill:build"]
					resources: {cpus: 2.0, memory_mb: 3072}
					outputs: {
						paths: ["services/mcp/public/ui-apps"]
						key: list.Concat([[
							"services/mcp/**", "products/**", "packages/quill/**",
							"frontend/src/**", "showcase/scripts/build_mcp_ui_apps.sh",
						], _buildOnceKey])
					}
					tasks: [{command: "../../showcase/scripts/build_mcp_ui_apps.sh"}]
				}
				schema_check: {
					services: false
					tasks: [
						{name: "Check MCP schema is up to date", command: "pnpm exec tsx scripts/generate-tool-schema.ts && pnpm exec oxfmt schema/tool-inputs.json && git diff --exit-code schema/tool-inputs.json", expect_no_drift: ["services/mcp/schema/tool-inputs.json"]},
						{name: "Check generated UI apps are up to date", command: "pnpm run generate:ui-apps && git diff --exit-code -- src/ui-apps/apps/generated/ src/resources/ui-apps.generated.ts", expect_no_drift: ["services/mcp/src/ui-apps/apps/generated/**", "services/mcp/src/resources/ui-apps.generated.ts"]},
						{name: "Lint tool names", command: "pnpm lint-tool-names"},
						{name: "Build API CLI release bundle", command: "trap 'rm -f ../../cli/lib/posthog-api-cli.mjs; rmdir ../../cli/lib ../../cli 2>/dev/null || true' EXIT && pnpm run build:cli:release && test -s ../../cli/lib/posthog-api-cli.mjs"},
					]
				}
				build: {
					services: false
					tasks: [{command: "../../showcase/scripts/check_mcp_ui_apps.sh", filter: include: _mcpUiAppsFiles}]
				}
			}
		}
		"live_harness": _harness & {
			name:        "live_harness"
			title:       "Live PostHog stack"
			technology:  ["python", "typescript"]
			depends_on:  ["test_env", "geoip"]
			watch_paths: ["showcase/scripts/live_posthog.sh", "showcase/scripts/rust_ci_env.sh", "bin/celery-queues.env"]
		}
		"e2e_harness": _harness & {
			name:        "e2e_harness"
			title:       "Playwright E2E runner"
			technology:  ["python", "typescript"]
			depends_on:  ["live_harness", "build_once"]
			watch_paths: ["showcase/scripts/run_e2e_tests.sh", "showcase/scripts/build_e2e.sh"]
		}
		"e2e": {
			name:             "e2e"
			title:            "PostHog Playwright End-to-End Suite"
			kind:             "verification"
			domain:           "verification"
			technology:       ["typescript", "python", "rust"]
			root:             "."
			cargo: workspace: "rust"
			depends_on:       ["base", "products", "frontend", "proto", "e2e_harness", "vitest_marker"]
			workspace_scope: include: list.Concat([_djangoTree, [
				"playwright", "frontend", "packages", "services/mcp/src/ui-apps", "tools/openapi-codegen",
				"nodejs", "rust", "proto", "docker", "infra",
			]])
			tags: ["e2e", "playwright"]
			watch_paths: list.Concat([[
				"playwright/**", "products/*/frontend/e2e/**",
				"tools/playwright_spec_selection.py", "tools/playwright_area_map.json",
				"tools/test_playwright_spec_selection.py", "rust/persons_migrations/**",
				"showcase/scripts/live_footprint.py", "showcase/scripts/rust_footprint.py",
				"showcase/scripts/node_reads.mjs",
			], _liveCaptureRust, _liveIngestionNode])
			jobs: test: {
				worker:    "standard"
				recorder:  "own"
				shards:    1
				resources: {cpus: 6, memory_mb: 11264}
				needs:     ["frontend:build"]
				tasks: [
					{name: "Build", command: _frontendBuild + " && showcase/scripts/build_e2e.sh", timeout: "30m"},
					{name: "Run Tests", command: "showcase/scripts/run_e2e_tests.sh {targets}", timeout: "60m"},
				]
				target_scope: {
					fallback: "all"
					tests:    ["playwright/e2e/**/*.spec.ts", "products/*/frontend/e2e/**/*.spec.ts"]
					rules: [
						{match: ["posthog/dags/**", "products/*/dags/**"], action: "ignore"},
						{
							match: [
								"playwright/**/*.ts", "products/*/frontend/e2e/**/*.ts",
								"frontend/src/**/*.{ts,tsx,js,jsx,mjs}",
								"products/*/frontend/**/*.{ts,tsx,js,jsx}",
								"ee/frontend/**/*.{ts,tsx,js,jsx}",
							]
							engine:      "typescript"
							granularity: "file"
						},
						{
							match:       ["posthog/**/*.py", "ee/**/*.py", "common/**/*.py", "products/**/*.py"]
							engine:      "python"
							granularity: "file"
						},
						{match: _liveIngestionNodeTests, action: "ignore"},
					]
				}
			}
			uses: _liveServices
		}
		"tooling": {
			name:            "tooling"
			title:           "PostHog Developer Tooling & Hogli Framework"
			technology:      "python"
			root:            "tools/hogli-commands"
			depends_on:      ["py-root", "geoip"]
			// The repository files hogli's tests read or probe (their reach footprints): ci-preflight's
			// API ratchet, triggers and workspace lockfiles; test_runner's detection of each
			// ecosystem's tests (a directory it walks whole is listed whole).
			workspace_scope: include: [
				"devenv", ".github/actions", ".github/scripts/migration-deletion-allowlist.txt", "frontend/package.json", "services/mcp/tsconfig.json",
				"frontend/src/generated/core/api.ts", "frontend/src/lib/api.ts", "frontend/src/lib/api-ratchet-baseline.txt", "frontend/src/lib/constants.tsx",
				"frontend/src/lib/components/AgentObjectTags/objectKinds.generated.ts", "frontend/src/scenes/sceneTypes.ts",
				"frontend/src/scenes/dashboard/DashboardHeader.test.tsx",
				"packages/agent/package.json", "packages/agent/biome.jsonc", "packages/agent/pnpm-workspace.yaml", "packages/agent/pnpm-lock.yaml",
				"packages/agent/packages/agent/package.json", "packages/agent/packages/agent/src/utils/gateway.test.ts",
				"packages/agent/packages/agent-contracts/src/model-catalog.generated.ts", "packages/agent/packages/agent-contracts/src/objectTagKinds.generated.ts",
				"services/mcp/src/lib/oauth-scopes.generated.ts", "services/mcp/src/lib/trace-property-allowlist.generated.ts",
				"tools/hedgebox-dummy/package.json", "tools/hedgebox-dummy/pnpm-workspace.yaml",
				"cli/Cargo.toml", "cli/src/main.rs", "cli/src/utils/throttler.rs", "funnel-udf/Cargo.toml", "funnel-udf/src/lib.rs",
				"rust/capture/Cargo.toml", "rust/capture/src", "rust/capture/tests/events.rs",
				"livestream/events/filter_test.go", "tools/phrocs/go.mod", "tools/phrocs/internal/tui/app_test.go",
				"nodejs/package.json", "nodejs/tests/cdp/cdp-api.test.ts", "playwright/e2e",
			]
			watch_paths: [
				"tools/hogli-commands/**", "tools/hogli/**", "hogli.yaml", "devenv/**",
				"bin/[!cde]*", "bin/e[!n]*", "bin/en[!av]*", "bin/c[!e]*", "bin/d[!o]*", "bin/do[!w]*",
				"bin/download-[!m]*", "bin/{helpers,sandbox-shims,test}/**",
			]
			test: {
				dir:          "."
				isolate_home: true
				command:      "mkdir -p \"$HOME/.hogli/bin\" \"$HOME/.local/bin\" && printf '#!/bin/sh\\necho 0.18.1\\n' >\"$HOME/.hogli/bin/mutagen\" && printf '#!/bin/sh\\nexit 0\\n' >\"$HOME/.local/bin/ssh\" && chmod +x \"$HOME/.hogli/bin/mutagen\" \"$HOME/.local/bin/ssh\" && PATH=\"$PATH:$HOME/.local/bin\" uv run --no-sync pytest {targets}"
			}
			recorder:         "trace"
			record_resources: _recordPy
			target_scope: {
				tests:          ["tools/hogli-commands/hogli_commands/tests/**/test_*.py"]
				default_target: "tools/hogli-commands/hogli_commands/tests"
			}
		}
	}
}

pipeline: caches: {
	"frontend-tsgo": {
		name:    "frontend tsgo declaration-emit cache"
		paths:   [_tsgoCache]
		seed:    {}
		used_by: {components: ["frontend"], jobs: [pipeline.#jobs.typecheck]}
	}
	mypy: {
		name:    "mypy fine-grained cache"
		paths:   [".mypy_cache"]
		seed:    {}
		used_by: {components: ["products"], jobs: [pipeline.#jobs.typecheck]}
	}
}
