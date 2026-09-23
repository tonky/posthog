package replay

pipeline: {
	name:        "posthog-platform"
	description: "PostHog Analytics Platform: Accelerated CI/CD Pipeline (enact + enve)"
	env: {}
	jobs: {}
	workspace_scope: {
		include: [
			"tools",
			"showcase",
		]
	}
	triggers: {
		pull_request: {
			branches: [
				"master",
				"main",
				"perf/ci-modernization",
			]
			paths: []
		}
		push: {
			branches: [
				"master",
				"main",
				"perf/ci-modernization",
				"showcase/**",
			]
			paths: [
				"**/*",
			]
			tags: []
		}
		schedule: []
	}
	components: {
		"backend": {
			caches: {}
			codegen: {
				openapi: {
					checkUncommitted: true
					command:          "hogli build:openapi"
					originDir:        "."
					outputs: [
						"frontend/src/generated/",
					]
					watchPaths: [
						"posthog/api/**",
						"products/*/backend/api/**",
						"products/*/*.py",
					]
				}
			}
			dependsOnComponents: [
				"product_structure",
			]
			depends_on:  []
			description: "Django ASGI server, REST endpoints, ClickHouse queries, and products"
			fmt:         "python3 showcase/scripts/static_check.py backend fmt {changed_files}"
			jobs: {}
			lint:       "python3 showcase/scripts/static_check.py backend lint {changed_files}"
			max_shards: 8
			migrations: {
				checkDeletions: true
				command:        "python3 showcase/scripts/migrations_check.py {changed_files}"
				engine:         "django"
				goldenDump:     "showcase/data/schema-latest.sql.gz"
				migrationsDir:  "posthog/migrations"
				targetDatabases: []
			}
			name: "backend"
			resources: {
				cpus:      1.5
				memory_mb: 1800
			}
			root: "."
			scoping: {
				barrels: []
				domainRoots: [
					"posthog",
					"ee",
					"products",
				]
				fullRunPatterns: []
				selector: {
					command:   "enact scope -t python {changed_files}"
					fallback:  "none"
					format:    "lines"
					granularity: "file"
					originDir: "."
					timeout:   10
				}
				serviceMarkers: [
					"django_db",
					"BaseTest",
					"APITestCase",
					"ClickhouseTestMixin",
					"NonDeterministicDatabaseTestMixin",
					"posthog.test",
				]
				universalSymbols: []
			}
			secrets: {}
			services: {}
			shards: "auto"
			tags: [
				"backend",
				"django",
				"api",
				"products",
			]
			technology: "python"
			audit:      "bash showcase/scripts/repo_invariants.sh"
			test:       "bash showcase/scripts/run_sharded_pytest.sh {targets_file}"
			title:      "PostHog Core Django API & Analytics Backend"
			typecheck:  "python3 showcase/scripts/backend_runtime.py exec python3 showcase/scripts/typing_check.py {changed_files}"
			uses: [
				{
					protocol: "sql"
					target:   "postgres"
					title:    "Reads & writes app metadata"
				},
				{
					protocol: "redis"
					target:   "redis"
					title:    "Caches sessions & flags"
				},
				{
					protocol: "kafka"
					target:   "kafka"
					title:    "Event streaming broker"
				},
				{
					protocol: "http"
					target:   "clickhouse"
					title:    "Analytics DBMS"
				},
				{
					protocol: "http"
					target:   "seaweedfs"
					title:    "Object storage for staging & recordings"
				},
				{
					protocol: "grpc"
					target:   "temporal"
					title:    "Workflow engine for async tasks"
				},
			]
			watch_paths: [
				"posthog/**",
				"ee/**",
				"products/*/backend/**",
				"products/*/*.py",
			]
		}
		"frontend": {
			build:  "pnpm --filter=@posthog/frontend build"
			caches: {}
			codegen: {}
			dependsOnComponents: []
			depends_on: [
				{
					build:       "pnpm --filter=@posthog/quill* build"
					depends_on:  []
					description: "Reusable UI primitives, buttons, badges, and chart components"
					lint:        "pnpm --filter=@posthog/quill* lint"
					name:        "quill"
					root:        "packages/quill"
					tags: [
						"design-system",
						"frontend",
						"tokens",
					]
					technology: "typescript"
					title:      "PostHog Quill UI & Design System"
					watch_paths: [
						"packages/quill/**",
					]
				},
			]
			description: "React, Vite, Kea state logics, scenes, and visual regression tests"
			fmt:         "python3 showcase/scripts/static_check.py frontend fmt {changed_files}"
			jobs: {}
			lint: "python3 showcase/scripts/static_check.py frontend lint {changed_files}"
			name: "frontend"
			resources: {
				cpus:      2.0
				memory_mb: 5120
			}
			root: "."
			scoping: {
				barrels: []
				domainRoots: [
					"frontend/src",
					"products",
					"common",
					"packages",
				]
				fullRunPatterns: []
				selector: {
					command:   "enact scope -t ts {changed_files}"
					fallback:  "none"
					format:    "lines"
					granularity: "file"
					originDir: "."
					timeout:   10
				}
				serviceMarkers: []
				universalSymbols: []
			}
			secrets: {}
			services: {}
			shards: 4
			tags: [
				"frontend",
				"vite",
				"react",
				"kea",
			]
			technology: "typescript"
			test:       "python3 showcase/scripts/run_jest.py {targets_file}"
			title:      "PostHog Frontend Web Application"
			typecheck:  "python3 showcase/scripts/typescript_check.py {changed_files}"
			uses:       []
			watch_paths: [
				"frontend/**",
				"products/*/frontend/**",
			]
			worker: "depot-8"
		}
		"quill": {
			build:  "pnpm --filter=@posthog/quill* build"
			caches: {}
			codegen: {}
			dependsOnComponents: []
			depends_on:          []
			description:         "Reusable UI primitives, buttons, badges, and chart components"
			jobs: {}
			lint: "pnpm --filter=@posthog/quill* lint"
			name: "quill"
			root: "packages/quill"
			secrets: {}
			services: {}
			tags: [
				"design-system",
				"frontend",
				"tokens",
			]
			technology: "typescript"
			title:      "PostHog Quill UI & Design System"
			uses:       []
			watch_paths: [
				"packages/quill/**",
			]
		}
		"product_structure": {
			name:       "product_structure"
			title:      "Product structure and isolation"
			technology: "python"
			root:       "."
			watch_paths: [
				"products/**",
				"tach.toml",
				".importlinter",
			]
			lint: "python3 showcase/scripts/static_check.py products lint {changed_files}"
		}
		"rust_services": {
			name:       "rust_services"
			title:      "PostHog Rust Microservices (Capture & Feature Flags)"
			technology: "rust"
			root:       "."
			watch_paths: [
				"rust/**",
			]
			fmt:  "python3 showcase/scripts/static_check.py rust fmt {changed_files}"
			lint: "python3 showcase/scripts/static_check.py rust lint {changed_files}"
			test: "bash showcase/scripts/run_rust_tests.sh {changed_files}"
		}
		"hogvm": {
			name:       "hogvm"
			title:      "PostHog Hog VM & Bytecode Compiler"
			technology: "typescript"
			root:       "common/hogvm"
			watch_paths: [
				"common/hogvm/**",
			]
			test: "node --test"
		}
		"tooling": {
			name:       "tooling"
			title:      "PostHog Developer Tooling & Hogli Framework"
			technology: "python"
			root:       "tools/hogli-commands"
			watch_paths: [
				"tools/hogli-commands/**",
			]
			test: "uv run --no-sync pytest hogli_commands/tests/test_product_lint_cli.py hogli_commands/tests/test_ast_helpers.py"
		}
		"nodejs": {
			name:       "nodejs"
			title:      "PostHog Node.js Ingestion & Plugin Server"
			technology: "typescript"
			root:       "nodejs"
			watch_paths: [
				"nodejs/**",
			]
			fmt:   "python3 showcase/scripts/static_check.py nodejs fmt {changed_files}"
			lint:  "python3 showcase/scripts/static_check.py nodejs lint {changed_files}"
			build: "pnpm --filter=@posthog/nodejs build"
			test:  "pnpm --filter=@posthog/nodejs test"
			uses: [
				{
					protocol: "sql"
					target:   "postgres"
				},
				{
					protocol: "redis"
					target:   "redis"
				},
				{
					protocol: "kafka"
					target:   "kafka"
				},
				{
					protocol: "http"
					target:   "clickhouse"
				},
			]
		}
		"livestream": {
			name:       "livestream"
			title:      "PostHog Livestream & Realtime Event Gateway"
			technology: "go"
			root:       "livestream"
			watch_paths: [
				"livestream/**",
			]
			lint: "golangci-lint run --timeout=5m"
			test: "go test -v ./..."
			codegen: {
				easyjson: {
					checkUncommitted: true
					command:          "go run github.com/mailru/easyjson/easyjson@v0.9.0 events/kafka.go && go run github.com/mailru/easyjson/easyjson@v0.9.0 events/filter.go"
					originDir:        "livestream"
					outputs: [
						"events/*_easyjson.go",
					]
					watchPaths: [
						"events/kafka.go",
						"events/filter.go",
					]
				}
			}
		}
		"proto": {
			name:       "proto"
			title:      "PostHog Protocol Buffers & Schema Definitions"
			technology: "protobuf"
			root:       "proto"
			watch_paths: [
				"proto/**",
			]
			lint: "buf lint proto/"
		}
		"workflows": {
			name:       "workflows"
			title:      "GitHub Actions Workflows & Actionlint"
			technology: "yaml"
			root:       "."
			watch_paths: [
				".github/workflows/**",
				".github/actions/**",
				".github/actionlint.yaml",
			]
			lint: "python3 showcase/scripts/static_check.py workflows lint {changed_files}"
		}
		"mcp": {
			name:       "mcp"
			title:      "PostHog MCP AI Server & Toolchain"
			technology: "typescript"
			root:       "services/mcp"
			watch_paths: [
				"services/mcp/**",
				"products/*/mcp/**",
				"packages/llm-normalizer/**",
			]
			fmt:   "python3 showcase/scripts/static_check.py mcp fmt {changed_files}"
			lint:  "python3 showcase/scripts/static_check.py mcp lint {changed_files}"
			build: "pnpm --filter=@posthog/mcp build"
			test:  "pnpm --filter=@posthog/mcp test:unit"
		}
		"e2e": {
			name:       "e2e"
			title:      "PostHog Playwright End-to-End Suite"
			technology: "typescript"
			root:       "playwright"
			tags: [
				"e2e",
				"playwright",
			]
			watch_paths: [
				"playwright/**",
				"products/*/frontend/e2e/**",
				"tools/playwright_spec_selection.py",
				"tools/playwright_area_map.json",
			]
			test: "python3 ../showcase/scripts/run_playwright.py {changed_files}"
			dependsOnComponents: [
				"backend",
				"frontend",
			]
			uses: [
				{
					protocol: "http"
					target:   "server"
				},
				{
					protocol: "sql"
					target:   "postgres"
				},
				{
					protocol: "http"
					target:   "clickhouse"
				},
				{
					protocol: "redis"
					target:   "redis"
				},
				{
					protocol: "http"
					target:   "seaweedfs"
				},
				{
					protocol: "kafka"
					target:   "kafka"
				},
				{
					protocol: "grpc"
					target:   "temporal"
				},
				{
					protocol: "http"
					target:   "temporal-worker"
				},
			]
		}
	}
}
