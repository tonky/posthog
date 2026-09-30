package replay

import "enact.dev/schema"

pipeline: schema.#Pipeline & {
	name:        "posthog-platform"
	description: "PostHog Analytics Platform: Accelerated CI/CD Pipeline (enact + enve)"
	env: {}
	workspace_scope: {
		include: [
			".enact",
			"bin",
			"tools",
			"showcase",
			"patches",
		]
		ignore: [
			".agents/**",
			".github/**",
			"docs/internal/**",
			"docs/plans/**",
			"docs/published/**",
			"docs/superpowers/**",
			"*.md",
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
		}
		schedule: []
	}
	components: {
		"backend": {
			caches: {}
			description: "Django ASGI server, REST endpoints, ClickHouse queries, and products"
			fmt:          "uvx ruff format --check {changed_files}"
			jobs: {}
			lint:         "uvx ruff check {changed_files}"
			max_shards:   8
			migrate:      "python manage.py makemigrations --check --dry-run"
			schema_check: "./bin/hogli build:openapi && git diff --exit-code"
			name:         "backend"
			resources: {
				cpus:      1.5
				memory_mb: 1800
			}
			root: "."
			scoping: {
				barrels: []
				domain_roots: [
					"posthog",
					"ee",
					"products",
				]
				full_run_patterns: []
				service_markers: [
					"django_db",
					"BaseTest",
					"APITestCase",
					"ClickhouseTestMixin",
					"NonDeterministicDatabaseTestMixin",
					"posthog.test",
				]
				universal_symbols: []
			}
			services: {}
			shards: "auto"
			// Python sources and syrupy snapshots map to tests; any other file of the
			// component (a fixture, a template, SQL, configuration) runs every test.
			target_scope: {
				fallback: "none"
				rules: [{
					match: [
						"posthog/**/*.{py,ambr}",
						"ee/**/*.{py,ambr}",
						"products/*/backend/**/*.{py,ambr}",
						"products/*/*.py",
					]
					engine:      "python"
					granularity: "file"
				}]
			}
			tags: [
				"backend",
				"django",
				"api",
				"products",
			]
			technology: "python"
			audit:      "pytest posthog/test/repo_invariants"
			test:       "pytest -v --tb=short --reuse-db {targets} -m 'not async_migrations'"
			title:      "PostHog Core Django API & Analytics Backend"
			typecheck:  "mypy {changed_files}"
			uses: [
				{
					protocol: schema.#Protocol.Sql
					target:   pipeline.services.postgres
					title:    "Reads & writes app metadata"
				},
				{
					protocol: schema.#Protocol.Redis
					target:   pipeline.services.redis
					title:    "Caches sessions & flags"
				},
				{
					protocol: schema.#Protocol.Kafka
					target:   pipeline.services.kafka
					title:    "Event streaming broker"
				},
				{
					protocol: schema.#Protocol.Http
					target:   pipeline.services.clickhouse
					title:    "Analytics DBMS"
				},
				{
					protocol: schema.#Protocol.Http
					target:   pipeline.services.seaweedfs
					title:    "Object storage for staging & recordings"
				},
				{
					protocol: schema.#Protocol.Grpc
					target:   pipeline.services.temporal
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
			build: "pnpm --filter=@posthog/frontend build"
			caches: {}
			depends_on: [
				{
					build: "pnpm --filter=@posthog/quill* build"
					depends_on: []
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
			fmt:         "pnpm exec oxfmt --check --no-error-on-unmatched-pattern {changed_files}"
			jobs: {}
			lint:        "pnpm exec oxlint --no-error-on-unmatched-pattern {changed_files} --quiet"
			name:        "frontend"
			resources: {
				cpus:      2.0
				memory_mb: 5120
			}
			root: "."
			workspace_scope: {
				include: [
					"frontend",
					"docs/onboarding",
				]
			}
			scoping: {
				barrels: []
				domain_roots: [
					"frontend/src",
					"products",
					"common",
					"packages",
				]
				full_run_patterns: []
				service_markers: []
				universal_symbols: []
			}
			services: {}
			shards: 4
			// TS/JS sources and jest snapshots map to tests. Jest's moduleNameMapper
			// stubs styles and images, and snapshots.yml lists visual review baselines,
			// so they reach no test; any other file of the component (JSON, YAML, a
			// manifest) runs every test.
			target_scope: {
				fallback: "none"
				rules: [
					{
						match: [
							"frontend/**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts,snap}",
							"products/*/frontend/**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts,snap}",
						]
						engine:      "typescript"
						granularity: "file"
					},
					{
						match: [
							"frontend/**/*.{css,less,scss,svg,png}",
							"products/*/frontend/**/*.{css,less,scss,svg,png}",
							"frontend/snapshots.yml",
						]
						action: "ignore"
					},
				]
			}
			tags: [
				"frontend",
				"vite",
				"react",
				"kea",
			]
			technology: "typescript"
			test:       "pnpm --filter=@posthog/frontend test:unit -- {targets}"
			title:      "PostHog Frontend Web Application"
			typecheck:  "pnpm --filter=@posthog/frontend typescript:check"
			uses: []
			watch_paths: [
				"frontend/**",
				"products/*/frontend/**",
			]
			worker: "standard"
		}
		"quill": {
			build: "pnpm --filter=@posthog/quill* build"
			caches: {}
			depends_on: []
			description: "Reusable UI primitives, buttons, badges, and chart components"
			jobs: {}
			lint: "pnpm --filter=@posthog/quill* lint"
			name: "quill"
			root: "packages/quill"
			services: {}
			tags: [
				"design-system",
				"frontend",
				"tokens",
			]
			technology: "typescript"
			title:      "PostHog Quill UI & Design System"
			uses: []
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
			lint: "uvx tach check --dependencies --exclude 'tests,test,**/test_*.py,**/*_test.py' && uvx tach check --interfaces"
		}
		"rust_services": {
			name:       "rust_services"
			title:      "PostHog Rust Microservices (Capture & Feature Flags)"
			technology: "rust"
			root:       "."
			watch_paths: [
				"rust/**",
			]
			fmt:  "cargo fmt --check"
			lint: "cargo clippy --workspace --all-targets"
			test: "cargo test --workspace"
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
			fmt:   "pnpm exec oxfmt --check --no-error-on-unmatched-pattern {relative_changed_files}"
			lint:  "pnpm exec oxlint --no-error-on-unmatched-pattern {relative_changed_files} --quiet"
			build: "pnpm --filter=@posthog/nodejs build"
			test:  "pnpm --filter=@posthog/nodejs test"
			uses: [
				{
					protocol: schema.#Protocol.Sql
					target:   pipeline.services.postgres
				},
				{
					protocol: schema.#Protocol.Redis
					target:   pipeline.services.redis
				},
				{
					protocol: schema.#Protocol.Kafka
					target:   pipeline.services.kafka
				},
				{
					protocol: schema.#Protocol.Http
					target:   pipeline.services.clickhouse
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
			lint: "actionlint"
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
			fmt:   "pnpm exec oxfmt --check --no-error-on-unmatched-pattern {relative_changed_files}"
			lint:  "pnpm exec oxlint --no-error-on-unmatched-pattern {relative_changed_files} --quiet"
			build: "pnpm --filter=@posthog/mcp build"
			test:  "pnpm --filter=@posthog/mcp test:unit"
		}
		"e2e": {
			name:       "e2e"
			title:      "PostHog Playwright End-to-End Suite"
			technology: "typescript"
			root:       "playwright"
			browsers: {
				engine: "chromium"
				path:   "/tmp/.cache/ms-playwright"
				env:    "PLAYWRIGHT_BROWSERS_PATH"
				key: ["playwright/package.json", "pnpm-lock.yaml"]
				artifact: "tools/playwright-browsers-linux-amd64.tar.zst"
			}
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
			test: "pnpm exec playwright test {targets}"
			depends_on: [
				"backend",
				"frontend",
			]
			uses: []
		}
	}
}
