package replay

import (
	"list"

	"enact.dev/schema"
)

// Every pattern here is a root-anchored glob: `docs/**` is the top-level docs/ only, and
// `**/` is the only way to match at any depth.

// The services the Django suites (and the nodejs and rust suites, against their own
// databases) run against.
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

// What the Django migrations the nodejs and rust suites set their databases up with read,
// as ci-nodejs.yml's and ci-rust.yml's filters list them. Watched there rather than a
// dependency on `base`: a Django change outside the migrations doesn't run those suites.
_djangoMigrations: [
	"posthog/migrations/**",
	"ee/migrations/**",
	"posthog/management/commands/setup_test_environment.py",
]

// What the live stack's Node service runs (run_e2e_tests.sh's ingestion-general, `node
// nodejs/dist/index.js`, built by build_e2e.sh's turbo build with its `^build` workspace
// packages): the plugin server's sources and the assets it reads, and the packages it imports
// (package.json `workspace:` dependencies, transitively) with the crates the addons among them
// build from. index.ts imports every server mode, so the whole graph boots whatever the mode:
// declared rather than traced (the specs' node_reads.mjs preload never sees this process).
_liveIngestionNode: [
	"nodejs/src/**",
	"nodejs/assets/**",
	"nodejs/package.json",
	"nodejs/tsconfig.json",
	"common/hogvm/typescript/src/**",
	"common/hogvm/typescript/{package.json,tsconfig.json,tsconfig.build.json,.parcelrc}",
	"common/replay-headless/src/**",
	"common/replay-headless/{package.json,tsconfig.json,build.mjs}",
	"common/replay-shared/src/**",
	"common/replay-shared/package.json",
	"rust/common/hogvm/**",
	"rust/replay-anonymizer/**",
	"rust/replay-anonymizer-node/**",
]
// Its files no build of it reads: tests, their snapshots and helpers, and the sidecar tsconfig
// excludes. nodejs's own build and tests catch a type break there first.
_liveIngestionNodeTests: [
	"nodejs/src/**/*.test.ts",
	"nodejs/src/**/__snapshots__/**",
	"nodejs/src/**/__tests__/**",
	"common/hogvm/typescript/src/**/*.test.ts",
	"common/hogvm/typescript/src/**/__snapshots__/**",
	"common/hogvm/typescript/src/**/__tests__/**",
	"common/replay-headless/src/**/*.test.ts",
	"common/replay-headless/src/**/__snapshots__/**",
	"common/replay-headless/src/**/__tests__/**",
	"common/replay-shared/src/**/*.test.ts",
	"common/replay-shared/src/**/__snapshots__/**",
	"common/replay-shared/src/**/__tests__/**",
	"nodejs/src/**/_tests/**",
	"nodejs/src/ingestion/pipelines/sessionreplay/ml-mirror-image-scrub-sidecar/**",
]

// The files outside base's packages the Django project reads as data, or its tests load: the
// frontend's product and widget manifests, the products' schemas, seeds and Hog sources, the
// MCP tool catalog, and the plugin transpiler the tests run (build_plugin_transpiler.sh).
// Base watches them; its traces answer for them.
_baseData: [
	"frontend/src/products.json",
	"products/canvas/packages/canvas_builder/manifest.json",
	"products/notebooks/notebook-widget-catalog.json",
	"products/ai_observability/shared/**",
	"products/dashboards/backend/api/dashboard_template_schema.json",
	"products/demo/backend/logic/dashboard_template_seeds/**",
	"products/growth/backend/enrichment/*.hog",
	"products/signals/skills/*/references/*.json",
	"services/mcp/schema/tool-definitions-all.json",
	"common/plugin_transpiler/src/**",
	"common/plugin_transpiler/{package.json,build.mjs,tsconfig.json}",
]

// Storybook's configuration (common/storybook), which the frontend and storybook own, less
// the overlay's footprint instrumentation in it (patch 0017's enact-loads.ts and
// vite-enact-chunks-plugin.ts: storybook_harness's). Named file by file where the two sit
// beside upstream's files; a file upstream adds there is unowned until listed (the
// coverage audit names it).
_storybookConfig: [
	"common/storybook/*",
	"common/storybook/.storybook/{README.md,app-context.ts,main.ts,preview.tsx,test-runner.ts}",
	"common/storybook/.storybook/{decorators,public}/**",
	"common/storybook/.storybook/plugins/vite-{frontend-resolve,module-graph,sql-raw}-plugin.ts",
]

// A command prefix giving it a HOME of its own, removed after, for code under test that writes
// the user's (usecases/posthog/LEARNINGS.md: hogli's tests): XDG config, data and state follow
// it, XDG_CACHE_HOME (tool caches) stays. A process still holding a file there at the end (a
// daemon the command started) is named and ended. Inline, not a script: a new file under a
// directory the reach maps listed ages their readers.
_ownHome: "h=$(mktemp -d) && trap 'p=$(lsof -t +D \"$h\" 2>/dev/null | sort -u); [ -z \"$p\" ] || { echo \"own HOME: ending leftover pids $p\" >&2; kill $p; }; rm -rf \"$h\"' EXIT && HOME=$h XDG_CONFIG_HOME=$h/.config XDG_DATA_HOME=$h/.local/share XDG_STATE_HOME=$h/.local/state"

// frontend:typecheck's tsgo declaration-emit cache (its buildinfo and the declarations it
// records signatures from), git-ignored. The buildinfo names its files by path, so it must
// come back where it was written: the same checkout path (CI's workspace is fixed).
_tsgoCache: ".enact/state/tsgo"

// rust_services' build and lint target crates: their manifests stand for them, and upstream's
// determinator (rust_affected_crates.sh, built in the job: select_in_job) picks them.
_rustCrates: ["rust/*/**/Cargo.toml"]
_rustCrateRules: [
	// The other jobs' helpers and the test databases' (test_env's): no build or lint reads
	// them, and upstream's filter lists none.
	{match: [
		"showcase/scripts/run_rust_tests.sh",
		"showcase/scripts/rust_footprint.py",
		"showcase/scripts/rust_nextest.toml",
		"infra/**",
		"docker/**",
		"showcase/scripts/{test_databases.sh,template_inputs.py,template_publications.py,create_test_kafka_topics.py,seaweedfs_setup.sh}",
		"showcase/scripts/tests/**",
		"showcase/.gitignore",
	], action: "ignore"},
	{match: list.Concat([[
		"rust/**",
		"proto/**",
		"posthog/api/feature_flag.py",
		"posthog/models/feature_flag/flags_cache.py",
		"posthog/models/feature_flag/feature_flag.py",
	], _rustEveryCrate]), command: "showcase/scripts/rust_affected_crates.sh {changed_files}"},
]

// The products' frontend codegen scripts, which only openapi_types runs: the frontend
// and storybook cone audits skip them.
_productsFrontendBin: ["products/*/frontend/bin/**"]

// The Django project a suite imports or migrates: the directories its sparse cone needs
// (cone entries are plain paths, git's cone mode takes no globs).
_djangoTree: [
	"posthog",
	"ee",
	"products",
	"common",
	"bin",
	"tools",
	"packages/owners-yaml",
	"packages/personhog-proto",
]

// ci-mcp.yml's wrangler pre-build, from services/mcp: the UI apps into public/ and the
// instructions the server imports (both git-ignored), before either vitest config runs.
_mcpPrebuild: "../../showcase/scripts/build_mcp_ui_apps.sh && pnpm exec tsx scripts/copy-instructions.ts"

// The frontend's dist as Frontend CI's build job makes it (turbo's prepare, build:products,
// the frontend's build), once per source state (build_once.sh), quill and hogvm built inside
// it: frontend:build's job, and e2e:test's first build, which finds it current when
// restored from frontend:build's outputs (`needs`). From the checkout root.
_frontendBuild: "showcase/scripts/build_once.sh frontend-build frontend/dist/.enact-build-key frontend products common packages ee/frontend services/mcp/src/ui-apps package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json tsconfig.json patches -- bash -c 'showcase/scripts/build_quill.sh && showcase/scripts/build_hogvm.sh && bin/turbo --filter=@posthog/frontend prepare && showcase/scripts/build_products.sh && pnpm --filter=@posthog/frontend build'"

// What a build_once.sh build's key reads beside its inputs: the workspace's manifests, lock
// and configs, and the scripts running it. Each build's `outputs.key` is its build_once.sh
// inputs and these, so a dist restored by key is current to build_once.sh too.
_buildOnceKey: [
	"package.json",
	"pnpm-lock.yaml",
	"pnpm-workspace.yaml",
	"turbo.json",
	"tsconfig.json",
	"patches/**",
	"showcase/scripts/build_once.sh",
	"showcase/scripts/exclusive.sh",
	"showcase/scripts/build_quill.sh",
]

// The builds a job starting with build_mcp_ui_apps.sh restores: the UI apps and quill's dist,
// which it reads too (CI restores what a job needs, not what mcp:ui_apps needs in turn).
_mcpUiAppsNeeds: ["mcp:ui_apps", "quill:build"]

// ci-mcp-ui-apps.yml's `ui-apps` filter: what `mcp:build` (check_mcp_ui_apps.sh) runs for.
_mcpUiAppsFiles: [
	"services/mcp/src/ui-apps/**",
	"services/mcp/src/resources/ui-apps.generated.ts",
	"services/mcp/vite.ui-apps.config.ts",
	"services/mcp/scripts/build-ui-apps.ts",
	"services/mcp/scripts/generate-ui-apps.ts",
	"services/mcp/scripts/post-ui-apps-size-section.mjs",
	"services/mcp/scripts/yaml-config-schema.ts",
	"products/*/mcp/**",
	"services/mcp/definitions/*.yaml",
	"common/mosaic/**",
	"packages/quill/**",
	"products/product_analytics/frontend/insights/**",
	"products/*/frontend/generated/**",
	"showcase/scripts/check_mcp_ui_apps.sh",
	"showcase/scripts/build_mcp_ui_apps.sh",
]

// pytest's own patterns (python_files), under a suite's roots.
_pytestFiles: ["test_*.py", "*_test.py"]

// pytest's exits that mean it broke, not that tests failed: interrupted (a collection error,
// or pytest_fail_early.py's broken session fixture), internal error, usage error. enact stops
// the whole run on them; a test failure (1) runs on.
_pytestErrors: [2, 3, 4]

pipeline: schema.#Pipeline & {
	name:        "posthog-platform"
	description: "PostHog Analytics Platform: Accelerated CI/CD Pipeline (enact + enve)"
	env: {}
	// What every job's checkout holds: the environment, the pipeline, the CI config, the
	// overlay's helpers, and the top-level files (manifests, lockfiles, tool configuration)
	// with the uv workspace's members and pnpm's patches every install reads.
	workspace_scope: {
		include: [
			"enve.cue",
			"enve.lock",
			".enact",
			"cue.mod",
			".github",
			"showcase",
			"patches",
			"tools/hogli",
			"packages/owners-yaml",
			"packages/personhog-proto",
			"package.json",
			"pnpm-lock.yaml",
			"pnpm-workspace.yaml",
			"turbo.json",
			"tsconfig.json",
			"tsconfig.dev.json",
			"tsconfig.kea-typegen.json",
			".oxfmtrc.json",
			".oxlintrc.json",
			".prettierignore",
			".stylelintrc.js",
			".stylelintignore",
			".nvmrc",
			".kearc",
			"postcss.config.js",
			"pyproject.toml",
			"uv.lock",
			"conftest.py",
			"pytest.ini",
			"pytest_boot_gc.py",
			".test_quarantine.json",
			"manage.py",
			"hogli.yaml",
			"posthog.json",
			"owners.yaml",
			"tach.toml",
			"depot.json",
			"dist-workspace.toml",
			"dagster_cloud.yaml",
		]
		// Prose, editor, agent and container configuration no CI job reads (Dockerfiles are the
		// `dockerfiles` component's: hadolint, and the tasks product's sandbox tests read theirs).
		// Patterns are root-anchored: `**/` where any depth is meant. `.config/**` and `.mcp.json`
		// are the root's only: rust/.config/nextest.toml is rust_services' test config and the
		// desktop plugin's .mcp.json ships with it.
		ignore: [
			"**/*.md",
			"**/*.mdx",
			"**/LICENSE",
			"**/.env.*",
			"**/.gitignore",
			"**/.dockerignore",
			"compose.yaml",
			"**/docker-compose*.yml",
			"otel-collector-config.dev.yaml",
			".agents/**",
			"**/.claude/**",
			".codex/**",
			".cursor/**",
			".cursorignore",
			".cursorrules",
			".posthog-code/**",
			".mcp.json",
			".coderabbit.yaml",
			"**/.greptile/**",
			".interface-design/**",
			".config/**",
			"**/.editorconfig",
			".envrc",
			".easignore",
			".flox/**",
			".git-blame-ignore-revs",
			".github/ISSUE_TEMPLATE/**",
			".husky/**",
			".idea/**",
			".run/**",
			".trunk/**",
			"**/.vscode/**",
			".watchmanconfig",
			".worktreeinclude",
			".worktreelink",
			".zed/**",
		]
	}
	triggers: {
		pull_request: {
			branches: ["master", "main", "perf/ci-modernization"]
			paths: []
		}
		push: {
			branches: ["master", "main", "perf/ci-modernization", "perf/ci-showcase", "showcase/**"]
			paths: ["**/*"]
		}
		schedule: []
	}
	components: {
		// What every component needs: the environment, the pipeline, its generated workflow,
		// the overlay's trace-map generator and the lock the jobs' installs run under.
		"root": {
			name:  "root"
			title: "Environment & pipeline"
			root:  "."
			watch_paths: [
				"enve.cue",
				"enve.lock",
				// The pipeline's own files; its subdirectories are the state enact writes and the
				// helpers of components of their own (vitest/: vitest_marker's).
				".enact/*",
				"cue.mod/**",
				".github/workflows/ci.yml",
				"showcase/scripts/exclusive.sh",
				// The enact and enve builds the fork's tree commits for CI to install
				// (scripts/fork-push.sh in enact).
				"bin/linux-x86_64/**",
				"bin/linux-aarch64/**",
			]
		}
		// The build-once helper (a build per source state of its inputs, under exclusive.sh's
		// lock) the JavaScript and Python builds run: quill's and hogvm's dists, the plugin
		// transpiler (base), canvas's builder (products), the agent's install, the nodejs
		// suite's hogvm, the MCP UI apps, storybook's and e2e's builds. It runs no tests, and
		// only the components whose builds run it depend on it (helper_tests tests it): their
		// harness, so an edit runs them and ages none of their footprints.
		"build_once": {
			name:       "build_once"
			title:      "Build-once helper"
			technology: ["python", "typescript"]
			root:       "."
			depends_on: ["root"]
			watch_paths: ["showcase/scripts/build_once.sh"]
		}
		// How the agent's and mcp's vitest jobs run vitest (.enact/vitest/vitest.sh), and the
		// reporter and setup file it adds under enact's Node recorder, ending each test file's
		// record. They run no tests, and only those components depend on them: their harness,
		// so an edit runs them and ages none of their footprints. Under .enact/, which no
		// footprint lists: e2e's and the Python helpers' footprints list showcase/ and most
		// Python ones the repository root, so a file added there changes them all.
		"vitest_marker": {
			name:  "vitest_marker"
			title: "vitest runner and recorder marker"
			// No ecosystem: a shell script and two modules vitest loads by path.
			root:       "."
			depends_on: ["root"]
			watch_paths: [".enact/vitest/**"]
		}
		// Top-level files only the pnpm workspace's components use.
		"js-root": {
			name:       "js-root"
			title:      "pnpm workspace root"
			technology: "typescript"
			root:       "."
			depends_on: ["root"]
			watch_paths: [
				"package.json",
				"pnpm-lock.yaml",
				"pnpm-workspace.yaml",
				"turbo.json",
				"tsconfig.json",
				"tsconfig.*.json",
				".oxfmtrc.json",
				".oxlintrc.json",
				".prettierignore",
				".stylelintrc.js",
				".stylelintignore",
				".nvmrc",
				// pnpm's patchedDependencies.
				"patches/**",
			]
		}
		// The quarantined tests' list and what applies it to jest (frontend's and nodejs'
		// configs load jest.quarantine.ts and jest-retries.cjs) and to pytest (py-root's
		// conftest, through hogli's plugin): shared by the Python and JS suites, so only they
		// depend on it.
		"test_quarantine": {
			name:       "test_quarantine"
			title:      "Test quarantine"
			technology: ["python", "typescript"]
			root:       "."
			depends_on: ["root"]
			watch_paths: [
				".test_quarantine.json",
				"frontend/jest.quarantine.ts",
				".github/scripts/jest-retries.cjs",
			]
		}
		// Top-level files only the root uv project's components use, and its install.
		"py-root": {
			name:       "py-root"
			title:      "uv project root"
			technology: "python"
			root:       "."
			depends_on: ["root", "test_quarantine"]
			// Every pytest run from the root loads conftest.py, which imports posthog.test and
			// with it the Django project (settings load every app, core's, ee's and the
			// products'), with the data files the project reads at import.
			workspace_scope: include: list.Concat([_djangoTree, [
				".depot/workflows",
				".semgrep/rules/devex",
				".stamphog",
				"docker/clickhouse",
				"frontend/src/taxonomy/core-filter-definitions-by-group.json",
				"livestream/bot",
				"rust/feature-flags/src/properties",
				"rust/feature-flags/tests/fixtures",
				"services/hogql-language-service/internal/completion",
				"services/mcp/schema",
				"services/mcp/src/templates",
			]])
			watch_paths: [
				"pyproject.toml",
				"uv.lock",
				"conftest.py",
				"pytest.ini",
				"pytest_boot_gc.py",
				"showcase/scripts/setup.sh",
				"showcase/scripts/backend_runtime.py",
			]
		}
		// The pytest plugins every Django-project pytest run loads (run_sharded_pytest.sh, the
		// live stacks): its shards' durations, fail-early and snapshot-worker hooks, and the
		// footprint recorder. They run no tests, and the suites loading them depend on them:
		// they are those suites' harness, left out of their footprints' digests and age, while
		// a change to them still selects every test whose footprint read them (helper_tests'
		// own tests of the plugins among them).
		"pytest_plugins": {
			name:       "pytest_plugins"
			title:      "pytest plugins"
			technology: "python"
			root:       "."
			depends_on: ["py-root"]
			watch_paths: ["showcase/pytest_plugins/**"]
		}
		// The runner of the Django-project pytest suites (base's, products' and dagster's
		// `run_sharded_pytest.sh`) and how it splits a shard into pytest runs
		// (product_pytest.py). They run no tests, and the suites they run depend on them: they
		// are those suites' harness, as the plugins are, while a change to them still runs
		// every suite they run whole (their traces don't read them) and helper_tests' tests of
		// them (test_product_runs, test_shard_provisioning).
		"pytest_runner": {
			name:       "pytest_runner"
			title:      "pytest runner"
			technology: "python"
			root:       "."
			depends_on: ["py-root", "pytest_plugins", "test_env", "geoip"]
			watch_paths: [
				"showcase/scripts/run_sharded_pytest.sh",
				"showcase/scripts/product_pytest.py",
			]
		}
		// The test databases, topics and buckets the Django, nodejs and rust suites share:
		// the services' configuration and the helpers that fork and seed them.
		"test_env": {
			name:        "test_env"
			title:       "Shared test databases & services"
			description: "Service configuration and the helpers forking and seeding test databases"
			technology:  "python"
			root:        "."
			// The helpers run the root project's interpreter (Django migrations, the topics
			// script), but don't depend on py-root: a uv.lock bump then runs base, whose suite
			// migrates the same databases, and not the nodejs and rust suites (as upstream's
			// filters, which list no Python lockfile for them).
			depends_on: ["root"]
			workspace_scope: include: ["infra", "docker"]
			watch_paths: [
				"infra/clickhouse/config.xml",
				"infra/clickhouse/start.sh",
				"infra/clickhouse/users.d/**",
				"infra/clickhouse/build_host_udfs.sh",
				"docker/**",
				"showcase/scripts/test_databases.sh",
				// The persons database's schema, which test_databases.sh migrates (sqlx) for every
				// suite's template, as the rust suites' and the live stacks' runners do theirs.
				"rust/persons_migrations/**",
				"showcase/scripts/template_inputs.py",
				"showcase/scripts/template_publications.py",
				"showcase/scripts/create_test_kafka_topics.py",
				"showcase/scripts/seaweedfs_setup.sh",
				// Ignores the helpers' and their tests' caches.
				"showcase/.gitignore",
			]
		}
		// The GeoIP database's installer (bin/download-mmdb), which the runners of the suites
		// reading share/GeoLite2-City.mmdb call before their tests (run_sharded_pytest.sh,
		// run_rust_tests.sh, run_flags_integration.sh, live_posthog.sh). It runs no tests and
		// only those runners' components depend on it (not nodejs, whose PR runs read a
		// committed fixture): their harness, so an edit runs the tests whose footprints read
		// the database (analysis.cue's GeoLite rule) and ages none of them.
		"geoip": {
			name:       "geoip"
			title:      "GeoIP database installer"
			// No ecosystem: a shell script (a Rust technology at the root would declare a
			// Cargo workspace there).
			root:       "."
			depends_on: ["root"]
			watch_paths: ["bin/download-mmdb"]
		}
		// The overlay helpers' own tests (unittest, outside the Django project's pytest
		// config). They run test_env's helpers (the test databases, topics, templates), the
		// build-once helper, py-root's (setup.sh, backend_runtime.py) and the pytest plugins
		// and runner, on which they depend, and the other suites' runners, which test_env can't
		// depend on back: watched here, as the nodejs and rust suites watch the Django
		// migrations, so a Django or nodejs code change doesn't run them.
		"helper_tests": {
			name:        "helper_tests"
			title:       "Overlay helpers' tests"
			description: "The unittest suite of the overlay's scripts: shard provisioning, runners, templates"
			technology:  "python"
			root:        "."
			// The plugins and the pytest runner its tests test (test_snapshot_worker,
			// test_fail_early, test_timings; test_product_runs, test_shard_provisioning).
			depends_on: ["test_env", "py-root", "pytest_plugins", "pytest_runner", "build_once"]
			watch_paths: [
				"showcase/scripts/tests/**",
				// nodejs's runner (test_nodejs_runner, test_nodejs_shard_databases).
				"showcase/scripts/run_nodejs_tests.sh",
				// rust_services' footprint recorder and release build (test_rust_footprint).
				"showcase/scripts/rust_footprint.py",
				"showcase/scripts/run_rust_release_build.sh",
				"showcase/scripts/live_footprint.py",
				// the live jobs' Node.js recorder (test_live_footprint).
				"showcase/scripts/node_reads.mjs",
				// openapi_types' drift check (test_no_drift).
				"showcase/scripts/no_drift.sh",
				// The UDFs ClickHouse loads (test_clickhouse_udfs).
				"posthog/user_scripts/**",
			]
			// unittest takes test files by path; the whole suite is its discovery. unittest has
			// no recorder: a recording traces each test file in a run of its own.
			test:     "uv run --no-sync python -m unittest {targets}"
			recorder: "trace"

			record_resources: _recordPy
			target_scope: {
				tests: ["showcase/scripts/tests/test_*.py"]
				default_target: "discover -s showcase/scripts/tests -t showcase/scripts/tests"
			}
		}
		// Django core: settings, models, the query engine and the API (upstream's "Django
		// tests – Core" and "– Temporal").
		"base": {
			name:        "base"
			title:       "PostHog Core Django API & Analytics Backend"
			description: "Django ASGI server, models, HogQL, REST endpoints and ClickHouse queries"
			technology:  "python"
			root:        "."
			depends_on: ["py-root", "pytest_plugins", "pytest_runner", "test_env", "build_once"]
			tags: ["backend", "django", "api"]
			workspace_scope: include: [
				"frontend/src/products.json",
				"frontend/src/taxonomy/core-filter-definitions-by-group.json",
				"frontend/src/lib/agentScopes.generated.ts",
				"frontend/src/lib/components/AgentObjectTags/objectKinds.generated.ts",
				"rust",
				"services",
				"livestream",
				"packages/agent",
				".depot",
				".semgrep",
				".stamphog",
				"AGENTS.md",
				"docker",
				"docker-compose.dev.yml",
				"docker-compose.base.yml",
				"docker-compose.profiles.yml",
			]
			// And the data the project reads at import or its tests load (_baseData).
			watch_paths: list.Concat([[
				"posthog/**",
				"ee/**",
				"manage.py",
				"common/__init__.py",
				"common/hogql_parser/**",
				"common/migration_utils/**",
				"common/fixtures/**",
				"common/ingestion/**",
				"packages/personhog-proto/**",
				// Read by posthog/product_db_router.py at runtime.
				"products/db_routing.yaml",
				// What the Django project imports from packages of their own (core_imports.rs):
				// HogVM's Python executor, the owners.yaml resolver (posthog/ownership), hogli's
				// quarantine plugin (posthog/conftest.py) and what the repo invariants test.
				"common/hogvm/__init__.py",
				"common/hogvm/python/**",
				"packages/owners-yaml/owners_yaml/**",
				"tools/hogli-commands/hogli_commands/{__init__,change_detection,projections}.py",
				"tools/hogli-commands/hogli_commands/{quarantine,product}/**",
				"tools/hogli/src/hogli/{__init__,manifest}.py",
				// Core imports the product apps back: a product change runs the core tests
				// importing it (the python rule below), the migrations check and the type
				// check, as upstream runs Core on one. Ruff stays the products' own.
				"products/**/*.py",
				// The repo invariants (`audit`) check rule ids the code names.
				".semgrep/**",
				"showcase/scripts/build_plugin_transpiler.sh",
				// Upstream's per-test durations, which balance the shards (analysis.cue).
				"showcase/scripts/fetch_test_durations.sh",
				"showcase/scripts/repo_invariants.sh",
			], _baseData])
			fmt: {
				command: "uv run --no-sync ruff format --check {changed_files}"
				filter: {include: ["**/*.py"], exclude: ["products/**"]}
			}
			lint: {
				command: "uv run --no-sync ruff check {changed_files}"
				filter: {include: ["**/*.py"], exclude: ["products/**"]}
			}
			// The repo invariants: pytest over posthog/test/repo_invariants on its own database
			// clones. Its xdist workers follow the job's CPUs (repo_invariants.sh's default,
			// nproc, ran 12-13 cores and 18 GB on a job planned as a 1-CPU static check).
			jobs: audit: {
				name:      "Audit"
				direct:    true
				services:  false
				resources: {cpus: 4.0, memory_mb: 8192}
				tasks: [{command: "PYTEST_NUM_WORKERS=$ENACT_SHARD_WORKERS ./showcase/scripts/repo_invariants.sh"}]
			}
			// Python CI's code quality (ty, mypy) is products:typecheck: one run over core's
			// packages and the products, as upstream's one repository-wide run.
			// A static check: makemigrations compares the migrations with the models and
			// needs no database, so it starts none (the migrate slot would start them).
			jobs: migrate: {
				name:     "Migrate"
				services: false
				tasks: [{
					name:    "Check Migrations"
					// The backend's venv: the env's python has no Django.
					command: "uv run --no-sync python manage.py makemigrations --check --dry-run"
					// What makemigrations compares: the migrations and the models' state, which
					// takes in what the models import (choices, defaults, validators): any Python
					// change, as ci-backend.yml validates on any backend change.
					filter: include: ["**/*.py"]
				}]
			}
			scoping: {
				domain_roots: ["posthog", "ee", "products"]
				service_markers: [
					"django_db",
					"BaseTest",
					"APITestCase",
					"ClickhouseTestMixin",
					"NonDeterministicDatabaseTestMixin",
					"posthog.test",
				]
			}
			// Python sources and syrupy snapshots map to tests; any other file of the
			// component (a fixture, a template, SQL, configuration) runs every test.
			target_scope: {
				fallback: "none"
				rules: [{
					match: [
						"posthog/**/*.{py,ambr}",
						"ee/**/*.{py,ambr}",
						"common/**/*.py",
						"packages/personhog-proto/**/*.py",
						// The products' (watched): the core tests importing what changed.
						"products/**/*.py",
						"packages/owners-yaml/owners_yaml/**/*.py",
						"tools/hogli-commands/hogli_commands/**/*.py",
						"tools/hogli/src/**/*.py",
					]
					engine:      "python"
					granularity: "file"
				}, {
					// Read, not imported: the tests whose footprints hold them (and those not traced).
					match:  _baseData
					engine: "reach"
				}, {
					// Rule data only the repo invariants read.
					match: [".semgrep/**"]
					action: "ignore"
				}]
				tests: [for root in ["posthog", "ee"] for f in _pytestFiles {"\(root)/**/\(f)"}]
				// pytest.ini's `--ignore=posthog/user_scripts`: no CI job runs the UDFs' tests, and
				// named as targets their versions' same-named modules (v7..v12/aggregate_funnel_test.py)
				// stop the shard's whole pytest at collection ("import file mismatch").
				// posthog/dags: the `dagster` component's suite, as ci-dagster.yml runs it.
				// posthog/api/test/rust_integration: `flags_integration`'s (here they skip
				// themselves: SKIP_RUST_INTEGRATION_TESTS).
				exclude: ["posthog/user_scripts/**", "posthog/dags/**", "posthog/api/test/rust_integration/**"]
			}
			// The transpiler's dist the tests run (build_plugin_transpiler.sh) is built in a task
			// before the tests'. A cold shard bootstraps the template databases
			// first: ~3060 Django migrations, 6.5-17 min on CI hardware and 45+ on a loaded dev
			// VM, once per migration set (template_inputs.py). Killed, it saves nothing and the
			// next run starts over, so the limit fits a cold bootstrap (ci-backend.yml's test
			// jobs: 40-60 min).
			jobs: test: {
				name:       "Test"
				max_shards: 12
				shards:     4
				// run_sharded_pytest.sh records (pytest_footprint.py).
				recorder: "own"
				// A shard waits on its services more than it computes (0.4-0.7 cores measured);
				// its pytest peaks at 1.6-2.8 GB (enact's dynamic adjustment suggests 2.6 GB).
				resources: {
					cpus:      0.75
					memory_mb: 2800
				}
				tasks: [{
					name:    "Build plugin transpiler"
					command: "showcase/scripts/build_plugin_transpiler.sh"
					timeout: "15m"
				}, {
					name: "Run Tests"
					// Through the env's bash, not the script's `#!/usr/bin/env` shebang: macOS's SIP
					// strips DYLD_* from /usr/bin/env's children, so the declared libraries' loader
					// path (libomp, which xgboost's wheel loads) never reached the tests.
					command:          "bash showcase/scripts/run_sharded_pytest.sh {targets}"
					timeout:          "90m"
					error_exit_codes: _pytestErrors
				}]
			}
			uses: _backendServices
		}
		// The product backends (upstream's "Product tests"), their Dagster jobs and evals.
		"products": {
			name:        "products"
			title:       "PostHog Product Backends"
			description: "Each product's Django app, Dagster assets and evaluation harnesses"
			technology:  "python"
			root:        "."
			// The product apps import core (and core imports some of them back). A core change
			// goes through the python rule below, which selects the product tests importing
			// what changed, as upstream's turbo-discover narrows to the products it reaches.
			depends_on: ["base", "py-root", "test_env"]
			workspace_scope: include: [
				"frontend/src/products.json",
				"rust",
				"services",
				"packages/agent",
				".stamphog",
				".dagster_home",
				"AGENTS.md",
				"docker",
			]
			tags: ["backend", "django", "products"]
			watch_paths: [
				"products/*.py",
				"products/ruff.toml",
				"products/*/*.py",
				"products/*/backend/**",
				"products/*/{dags,eval,evals,eval_harness,stats,fixtures,management,opensearch,observability,plan,adr,shared,scout,agent}/**",
				"products/{data_catalog,posthog_ai,support,tasks,web_analytics}/scripts/**",
				"products/stamphog/packages/**",
				// The tasks sandbox's build context copies the agent-shadow observer (its test
				// checks the context carries it).
				"packages/agent/agent-shadow/**",
				".stamphog/**",
				"dagster_cloud.yaml",
				".dagster_home/**",
			]
			fmt: {
				command: "uv run --no-sync ruff format --check {changed_files}"
				filter: include: ["**/*.py"]
			}
			lint: {
				command: "uv run --no-sync ruff check {changed_files}"
				filter: include: ["**/*.py"]
			}
			// No migrations check of its own: base's checks every app, and watches the products'
			// Python.
			// Python CI's code quality: ty, then mypy (its Django, DRF and pydantic plugins),
			// once over core's packages and the products with one fine-grained cache
			// (`mypy` in pipeline.caches), as upstream's one repository-wide run; here, because
			// the products depend on core, a core change runs it too. The rust_integration
			// tests' bare `from conftest import` binds, in upstream's `mypy .`, to
			// services/stripe-mock/tests/conftest.py (top-level "conftest"); without it among
			// the sources mypy follows the import to the root conftest.py, which pyproject
			// excludes and which fails its checks (10 errors). Python CI gives mypy 2 workers
			// on a 16 GB runner; this one run peaks at 9.4 GB cold (usecases/posthog/IMPROVEMENTS.md),
			// asked with a sixth more, inside a tonky-ci slot's 11 GB usable.
			// A static check: no services.
			jobs: typecheck: {
				direct:   true
				services: false
				worker:   "standard"
				resources: {cpus: 2.0, memory_mb: 11264}
				tasks: [{
					command: "uv run --no-sync ty check posthog ee common products && uv run --no-sync mypy --cache-fine-grained posthog ee common products services/stripe-mock/tests/conftest.py"
					env: MYPY_NUM_WORKERS: "2"
					// The products type-check against core: a core change checks them too.
					filter: {include: ["**/*.py", "**/*.pyi"], on_empty: "run_all"}
					timeout: "30m"
				}]
			}
			max_shards: 12
			shards:     4
			// A shard runs one pytest per product (run_sharded_pytest.sh, as upstream's turbo
			// runs each product's backend:test): a product's files stay on one shard, and each
			// product a shard gets costs it a process start (~17s with collection, measured).
			shard_groups: {by: "products/*/", overhead_s: 17}
			// A shard waits on its services more than it computes (0.4-0.7 cores measured);
			// its pytest peaks at 1.6-2.8 GB (enact's dynamic adjustment suggests 2.6 GB).
			resources: {
				cpus:      0.75
				memory_mb: 2800
			}
			scoping: {
				domain_roots: ["posthog", "ee", "products"]
				service_markers: [
					"django_db",
					"BaseTest",
					"APITestCase",
					"ClickhouseTestMixin",
					"NonDeterministicDatabaseTestMixin",
					"posthog.test",
				]
			}
			target_scope: {
				fallback: "none"
				rules: [{
					match: [
						"products/*.py",
						"products/*/*.py",
						"products/*/backend/**/*.{py,ambr}",
						"products/*/{dags,eval,evals,eval_harness,stats,management,opensearch,observability,shared,scout,agent,scripts,packages}/**/*.py",
						// Core (base's): the product tests importing what changed.
						"posthog/**/*.py",
						"ee/**/*.py",
						"common/**/*.py",
						"packages/owners-yaml/owners_yaml/**/*.py",
						"tools/hogli-commands/hogli_commands/**/*.py",
						"tools/hogli/src/**/*.py",
					]
					engine:      "python"
					granularity: "file"
				}, {
					// Read, not imported: core's data (_baseData) and the agent-shadow sources
					// the tasks sandbox's build context copies.
					match: list.Concat([_baseData, ["packages/agent/agent-shadow/**"]])
					engine: "reach"
				}]
				tests: [for f in _pytestFiles {"products/*/backend/**/\(f)"}]
			}
			// run_sharded_pytest.sh records (pytest_footprint.py).
			recorder: "own"
			test: {
				// Through the env's bash, not the script's `#!/usr/bin/env` shebang: macOS's SIP
				// strips DYLD_* from /usr/bin/env's children, so the declared libraries' loader path
				// (libomp, which xgboost's wheel loads) never reached the tests. The canvas
				// builder's node_modules first, as ci-backend.yml's "Install canvas builder
				// dependencies" (canvas' build tests run its esbuild), once per lockfile state.
				command: "showcase/scripts/build_once.sh canvas-builder-deps products/canvas/packages/canvas_builder/node_modules/.enact-build-key products/canvas/packages/canvas_builder/package.json products/canvas/packages/canvas_builder/package-lock.json -- npm ci --ignore-scripts --omit=dev --no-audit --no-fund --prefix products/canvas/packages/canvas_builder && bash showcase/scripts/run_sharded_pytest.sh {targets}"
				timeout: "90m"
				error_exit_codes: _pytestErrors
			}
			uses: _backendServices
		}
		"product_structure": {
			name:       "product_structure"
			title:      "Product structure and isolation"
			technology: "python"
			root:       "."
			depends_on: ["py-root"]
			// tach's modules are core's too (posthog, ee, common): a backend change checks
			// the boundaries, as ci-backend.yml's repo-checks runs on one. The products'
			// generated TypeScript isn't tach's.
			watch_paths: [
				"products/**/*.py",
				"posthog/**/*.py",
				"ee/**/*.py",
				"common/**/*.py",
				"products/*/product.yaml",
				"products/isolation_baseline.txt",
				"products/model_crossing_uses_baseline.txt",
				"tach.toml",
				".importlinter",
			]
			// tach.toml is in the cone (watched above): a missing one fails, as any violation
			// does.
			lint: "uvx tach check --dependencies --exclude 'tests,test,**/test_*.py,**/*_test.py' && uvx tach check --interfaces"
		}
		// ci-backend.yml's "Validate OpenAPI types": the API schema regenerated into the
		// frontend's, the products' and MCP's types, then checked unchanged. On a backend
		// change (its dependencies) or one to the generated files and what generates them,
		// as its openapi_types filter. That filter's Markdown (MCP prompts and exec-docs
		// templates) is ignored pipeline-wide, and an ignore outranks a glob watch: the one
		// listed by name is watched.
		"openapi_types": {
			name:       "openapi_types"
			title:      "Generated OpenAPI types"
			technology: "python"
			root:       "."
			depends_on: ["base", "products"]
			watch_paths: [
				"frontend/src/generated/**",
				"frontend/src/lib/agentScopes.generated.ts",
				"products/*/frontend/generated/**",
				"services/mcp/src/generated/**",
				"services/mcp/src/api/generated.ts",
				"tools/openapi-codegen/**",
				"services/mcp/scripts/**",
				"frontend/bin/generate-openapi-types.mjs",
				// build:openapi's build:widget-types runs it. Named, as frontend and storybook
				// ignore products/*/frontend/bin: an exact watch outranks an ignore.
				"products/dashboards/frontend/bin/generate-widget-config-zod.mjs",
				"frontend/src/lib/api-orval-mutator.ts",
				"services/mcp/definitions/**/*.yaml",
				"products/*/mcp/**/*.yaml",
				"services/mcp/schema/tool-definitions.json",
				"services/mcp/schema/tool-definitions-v2.json",
				"services/mcp/src/tools/generated/**",
				"services/mcp/schema/generated-tool-definitions.json",
				"services/mcp/schema/tool-definitions-all.json",
				"services/mcp/src/templates/sections/**",
				"services/mcp/schema/exec-command-reference.md",
				"showcase/scripts/no_drift.sh",
			]
			// As there: the regeneration and MCP's scaffold-yaml sync, then no tracked file
			// changed. no_drift.sh compares against the checkout's state before, which the
			// overlay's patches modify (a bare `git diff --exit-code` fails on them).
			schema_check: "showcase/scripts/no_drift.sh bash -c './bin/hogli build:openapi && pnpm --filter=@posthog/mcp run scaffold-yaml -- --sync-all'"
			// It loads Django (every app) for the schema, as base's tests.
			resources: {cpus: 1.0, memory_mb: 2400}
		}
		"frontend": {
			name:        "frontend"
			title:       "PostHog Frontend Web Application"
			description: "React, Vite, Kea state logics, scenes, and visual regression tests"
			technology:  "typescript"
			root:        "."
			// The hogvm package it imports (common/hogvm/typescript) reaches its tests
			// through their imports: a dependency would run them on the VM's Python changes.
			// quill's build need not run first (simulate's INTER_COMPONENT_BUILD_ORDER_HAZARD
			// info): the build and typecheck build quill themselves (pnpm and turbo
			// `--filter=@posthog/frontend...`), jest maps @posthog/quill to its sources, and
			// fmt and lint read sources only.
			depends_on: ["js-root", "quill", "test_quarantine"]
			tags: ["frontend", "vite", "react", "kea"]
			workspace_scope: {
				include: [
					"frontend",
					"products",
					"packages",
					"common",
					"docs/onboarding",
					"playwright",
					"services/mcp",
				]
				// The products' codegen scripts (generate-widget-config-zod.mjs imports
				// tools/openapi-codegen): no frontend job runs them, and upstream's frontend
				// filter takes no products/**/*.mjs, so the cone audit skips their imports.
				// openapi_types runs them (hogli build:openapi) and watches them by name, so
				// a change to one runs it, and the frontend's fmt and lint as before.
				ignore: _productsFrontendBin
			}
			watch_paths: list.Concat([[
				"frontend/**",
				"products/*/frontend/**",
				"products/*/*.{ts,tsx,json}",
				"products/games/**",
				"products/canvas/packages/**",
				"products/visual_review/cli/**",
				"docs/onboarding/**",
				"common/esbuilder/**",
				"common/tailwind/**",
				"common/replay-shared/**",
				// Workspace packages and data the frontend imports: HogVM's (lib/hog.ts, the
				// debug REPL), and ai_observability's.
				"common/hogvm/typescript/src/**",
				"common/hogvm/typescript/package.json",
				"packages/llm-normalizer/src/**",
				"packages/llm-normalizer/package.json",
				"products/ai_observability/shared/**",
				".kearc",
				// The typed-events generator's config for frontend/src/lib/posthog-typed.ts.
				"posthog.json",
				"postcss.config.js",
				// Its build:products, under the lock every job takes (e2e, storybook too).
				"showcase/scripts/build_products.sh",
				"bin/validate-setup-tasks.mjs",
			], _storybookConfig])
			// As Frontend CI's build (_frontendBuild), once per source state for it and
			// e2e:test, which restores its dist (`needs`).
			jobs: build: {
				services: false
				builds:   true
				// esbuild's Go service holds every bundle (the app, the exporter, the workers,
				// the toolbar) at once, ~7 GB live; under Go's default GC it grows past 10 GB.
				// GOMEMLIMIT=6GiB holds it near its live set at no wall cost (14.0 GB peak
				// before, usecases/posthog/IMPROVEMENTS.md): 9.0 GB on the Mac, 8.3 GB on a tonky-ci
				// x86_64 slot; asked with a tenth more.
				// esbuild and sass keep 4 cores busy.
				worker:    "standard"
				resources: {cpus: 4.0, memory_mb: 10240}
				outputs: {
					paths: ["frontend/dist"]
					key: list.Concat([[
						"frontend/**",
						"products/**",
						"common/**",
						"packages/**",
						"ee/frontend/**",
						"services/mcp/src/ui-apps/**",
						"showcase/scripts/build_hogvm.sh",
						"showcase/scripts/build_products.sh",
					], _buildOnceKey])
				}
				tasks: [{command: _frontendBuild, env: GOMEMLIMIT: "6GiB"}]
			}
			fmt:   "pnpm exec oxfmt --check --no-error-on-unmatched-pattern {changed_files}"
			lint:  "pnpm exec oxlint --no-error-on-unmatched-pattern {changed_files} --quiet"
			// As Frontend CI's typechecking, one task per step: the products' manifests (and
			// their drift check), Kea's logic types, tsgo over the whole program, then the drift
			// checks, each filtered on what its generator reads. Kea typegen and tsgo are called
			// directly (upstream's scripts set a 16 GB heap). tsgo checks warm from its
			// declaration-emit cache (`_tsgoCache`, usecases/posthog/LEARNINGS.md: under
			// `--noEmit` its buildinfo records no signatures, so every edit rechecked everything):
			// an edit that keeps a file's declarations rechecks that file, one that changes them
			// rechecks the program (sound); without the cache it checks cold and writes it.
			// One checker under GOMEMLIMIT=10GiB (which bounds the Go heap while it stays above
			// the live heap) and an 8 GB typegen heap fit the job in 12 GB, where upstream's
			// defaults peaked at 22-25 GB on Linux (ISSUES U32). Upstream runs it on
			// depot-ubuntu-24.04-8 (32 GB).
			jobs: typecheck: {
				direct:    true
				worker:    "standard"
				resources: {cpus: 2.0, memory_mb: 12288}
				tasks: [
					{
						name:    "Build products"
						command: "showcase/scripts/build_quill.sh && showcase/scripts/build_hogvm.sh && pnpm exec turbo --filter=@posthog/frontend prepare && showcase/scripts/build_products.sh && git diff --exit-code -- frontend/src/products.tsx frontend/src/products.json"
					},
					{
						name:    "Kea typegen"
						command: "NODE_OPTIONS=--max-old-space-size=8192 frontend/node_modules/.bin/kea-typegen write --delete --show-ts-errors"
					},
					{
						name:    "tsgo"
						command: "GOMEMLIMIT=10GiB pnpm --filter=@posthog/frontend exec tsgo --noEmit false --emitDeclarationOnly --outDir ../\(_tsgoCache)/out --rootDir .. --tsBuildInfoFile ../\(_tsgoCache)/frontend.tsbuildinfo --checkers 1"
						timeout: "20m"
					},
					{
						// Both generators load the whole TS program (tsconfig.json), so any source
						// may change them (schema/index.ts imports ~4200 of the repository's files).
						name: "Schema drift"
						command: "pnpm --filter=@posthog/frontend schema:build:json && git diff --exit-code -- frontend/src/queries/schema.json frontend/src/queries/validators.js && NODE_OPTIONS=--max-old-space-size=8192 pnpm --filter=@posthog/frontend mobile-replay:schema:build:json && git diff --exit-code -- frontend/src/scenes/session-recordings/mobile-replay/schema/web/rr-web-schema.json frontend/src/scenes/session-recordings/mobile-replay/schema/mobile/rr-mobile-schema.json"
						filter: include: [
							"**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts}",
							"**/tsconfig*.json",
							"**/package.json",
							"frontend/src/queries/schema.json",
							"frontend/src/scenes/session-recordings/mobile-replay/schema/**",
						]
					},
					{
						// It reads scenes/urls.ts and every product's manifest.tsx.
						name:    "App URL manifest"
						command: "pnpm --filter=@posthog/frontend build:app-urls:check"
						filter: include: [
							"frontend/bin/build-app-url-manifest.mjs",
							"frontend/src/scenes/urls.ts",
							"products/*/manifest.tsx",
							"services/mcp/src/tools/links/app-url-manifest.json",
						]
					},
					{
						name:    "Setup tasks"
						command: "node bin/validate-setup-tasks.mjs"
						filter: include: [
							"bin/validate-setup-tasks.mjs",
							"frontend/src/generated/core/api.schemas.ts",
							"frontend/src/lib/components/ProductSetup/productSetupRegistry.ts",
						]
					},
				]
			}
			resources: {
				cpus:      2.0
				memory_mb: 5120
			}
			scoping: {
				domain_roots: ["frontend/src", "products", "common", "packages"]
			}
			// TS/JS sources and jest snapshots map to tests. Jest's moduleNameMapper stubs
			// styles and images, and snapshots.yml lists visual review baselines, so they
			// reach no test; any other file of the component (JSON, YAML) runs every test.
			target_scope: {
				fallback: "none"
				rules: [
					{
						match: [
							"frontend/**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts,snap}",
							"products/*/frontend/**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts,snap}",
							"products/*/*.{ts,tsx}",
							"products/games/**/*.{ts,tsx}",
							"docs/onboarding/**/*.{ts,tsx}",
							// common's packages, storybook's configuration without the overlay's
							// instrumentation (no frontend test imports it; storybook's harness).
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
						// What the sources import that the typescript engine doesn't follow:
						// llm-normalizer's recipes (`?raw`), the shared data, @posthog/hogvm
						// (jest maps it to its sources, the build bundles its dist).
						match: [
							"packages/llm-normalizer/src/**/*.yaml",
							"products/ai_observability/shared/**",
							"common/hogvm/typescript/**",
						]
						engine: "reach"
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
				tests: [
					"frontend/**/*.test.{ts,tsx,js,jsx}",
					"products/*/frontend/**/*.test.{ts,tsx,js,jsx}",
				]
			}
			// No --passWithNoTests: the targets are test files, so a run finding none of them
			// (a path jest's config ignores) fails instead of passing untested.
			// CI=true as on GitHub's runners: jest-retries.cjs retries a failed test once only
			// under CI (utils.test.ts' compareTopLevelSections fails its first attempt upstream too).
			// Jest has no recorder, and a worker reuses what it transformed for one test file
			// in the next: a recording traces each test file in a jest run of its own. Products
			// are built in a task of their own, so the traces leave out build:products' digest,
			// which reads every product's files (each test would reach all of them). So is
			// jest's module map (`--listTests` builds and saves it): cold, as on a fresh checkout
			// or CI runner, it reads every file under the config's roots, ~17.4k charged to the
			// first traced test of each shard.
			jobs: test: {
				name:      "Test"
				shards:    4
				resources: {cpus: 2.0, memory_mb: 5120}
				recorder:  "trace"
				recorded_by: ["enact-node"]
				tasks: [
					{name: "Build products", command: "showcase/scripts/build_products.sh"},
					{name: "Warm jest", command: "CI=true pnpm --filter=@posthog/frontend exec jest --listTests >/dev/null"},
					{name: "Run Tests", command: "CI=true pnpm --filter=@posthog/frontend exec jest --maxWorkers=2 --forceExit {targets}"},
				]
			}
			worker: "standard"
		}
		"quill": {
			name:        "quill"
			title:       "PostHog Quill UI & Design System"
			description: "Reusable UI primitives, buttons, badges, and chart components"
			technology:  "typescript"
			root:        "packages/quill"
			depends_on: ["js-root", "build_once"]
			tags: ["design-system", "frontend", "tokens"]
			watch_paths: [
				"packages/quill/**",
				// Its build, which every job needing its dist runs (frontend, mcp, e2e, storybook).
				"showcase/scripts/build_quill.sh",
			]
			// Once per source state for every job that needs its dist (build_quill.sh): the UI
			// apps' build and the mcp jobs (`needs`). A job running turbo's prepare builds quill
			// again without turbo's cache (CI has none), so the frontend's and storybook's
			// builds don't: needing it would only start them a build level later.
			jobs: build: {
				services: false
				builds:   true
				outputs: {
					paths: ["packages/quill/packages/*/dist"]
					key: list.Concat([["packages/quill/**"], _buildOnceKey])
				}
				tasks: [{command: "../../showcase/scripts/build_quill.sh"}]
			}
			// No quill package has a lint script: upstream's Frontend formatting job runs
			// `oxlint --quiet` from the root over the whole tree (its .oxlintrc.json), quill
			// included. Its oxfmt check covers products, frontend/src and docs only.
			lint: "cd ../.. && pnpm exec oxlint --no-error-on-unmatched-pattern {changed_files} --quiet"
		}
		"agent": {
			name:        "agent"
			title:       "PostHog Agent Runtime & SDKs"
			description: "PostHog agent runtime and the packages it bundles"
			technology:  "typescript"
			// A pnpm workspace of its own (its lockfile, catalog and turbo), installed as
			// upstream's desktop-test.yml does.
			root: "packages/agent"
			depends_on: ["root", "build_once", "vitest_marker"]
			// The build and test jobs install into one node_modules: one at a time (exclusive.sh).
			build: "../../showcase/scripts/exclusive.sh agent-node-modules pnpm install --frozen-lockfile && pnpm run build"
			// One job, as desktop-test.yml's unit-test (which also covers a packages/agent change):
			// its `pnpm test` is turbo's `test`, each package's `vitest run` after its
			// dependencies' builds. Here the builds (every package but the agent, which no other
			// imports) run in a task of their own, and agent_vitest.sh gives each package's vitest
			// its own test files. A recording traces each test file in a run of its own, with the
			// functions it ran (vitest.sh's marker ends each file's record).
			jobs: test: {
				name:     "Test"
				shards:   1
				recorder: "trace"
				recorded_by: ["enact-node"]
				tasks: [
					// The install once per lockfile state (build_once.sh): every pnpm install
					// probes the directory with a temporary file, which a recording would take
					// for a change to the packages/agent listing its tests read.
					{name: "Build", command: "cd ../.. && showcase/scripts/build_once.sh agent-node-modules packages/agent/node_modules/.enact-build-key packages/agent/package.json packages/agent/pnpm-lock.yaml packages/agent/pnpm-workspace.yaml 'packages/agent/packages/*/package.json' -- pnpm --dir packages/agent install --frozen-lockfile && cd packages/agent && pnpm exec turbo run build --filter='!@posthog/agent'"},
					{name: "Run Tests", command: "../../showcase/scripts/agent_vitest.sh {relative_targets}"},
				]
			}
			watch_paths: ["showcase/scripts/agent_vitest.sh"]
			// Each package's vitest.config.ts includes `src/**/*.test.ts` (vitest's default
			// where a package has none). The agent's e2e/ suite (test:e2e) drives real model
			// turns: desktop-test.yml's e2e job, with model API keys.
			target_scope: tests: ["packages/agent/packages/*/src/**/*.test.ts"]
		}
		"rust_services": {
			name:       "rust_services"
			title:      "PostHog Rust Microservices (Capture & Feature Flags)"
			// Python too: its jobs set their databases up with the backend's Django (the test
			// template, setup_test_environment), as ci-rust.yml's test job installs the backend's
			// dependencies. Its install is what a run of rust_services alone prepares.
			technology: ["rust", "python"]
			// The workspace is rust/ (there is no Cargo.toml at the root).
			root: "rust"
			// geoip: run_rust_tests.sh installs the GeoIP database the flags service's tests
			// read, and ci-rust.yml's filter marks every crate affected by its installer.
			depends_on: ["test_env", "proto", "geoip"]
			// The Django project too: run_rust_tests.sh clones the backend's test template
			// (the schema feature-flags reads, which upstream's setup_test_environment
			// migrates), and a key miss builds it by running every app's migrations
			// (test_databases.sh). The services' configuration is under docker/ and infra/.
			workspace_scope: include: list.Concat([_djangoTree, ["rust", "proto", "docker", "infra"]])
			watch_paths: list.Concat([[
				"rust/**",
				// The feature-flag cache the flags service reads, as ci-rust.yml.
				"posthog/api/feature_flag.py",
				"posthog/models/feature_flag/flags_cache.py",
				"posthog/models/feature_flag/feature_flag.py",
				"showcase/scripts/run_rust_tests.sh",
				"showcase/scripts/rust_footprint.py",
				"showcase/scripts/rust_ci_env.sh",
				"showcase/scripts/rust_nextest.toml",
				"showcase/scripts/{run_rust_release_build.sh,rust_affected_crates.sh}",
				// Clippy's configuration (the overlay's: ends clippy's search up the tree).
				"clippy.toml",
			], _djangoMigrations])
			fmt: "cargo fmt --check"
			// ci-rust.yml's linting job after its format check: clippy denying warnings and
			// cargo-shear (unused dependencies), with the toolchain and cargo-shear upstream
			// pins (enve.cue: newer ones fail it). Its system OpenSSL, not the vendored one.
			// Clippy on the crates the change affects (the build job's targets: upstream's
			// determinator), the workspace on a full run or a crate given by its manifest.
			// Upstream's `cargo check --all-features` after it is left out: clippy
			// `--all-targets` already type-checks every target it would (~1.5 of 4.5 min cold).
			// Upstream lints on a 4-core runner; the preflight stage runs on `standard`, and
			// enact sizes CARGO_BUILD_JOBS from `cpus`.
			jobs: lint: {
				direct:   true
				services: false
				resources: {cpus: 2.0, memory_mb: 6000}
				// clippy's configuration lints every crate.
				target_scope: {
					select_in_job: true
					tests:         _rustCrates
					rules: list.Concat([[{match: ["clippy.toml"], action: "full_component"}], _rustCrateRules])
				}
				tasks: [{
					command: "set -- {targets}; p=--workspace; case \" $* \" in *Cargo.toml*|'  ') ;; *) p=$(printf -- '-p %s ' \"$@\") ;; esac; cargo clippy --all-targets --all-features $p -- -D warnings && cargo shear"
					env: {
						OPENSSL_NO_VENDOR:       "1"
						CARGO_INCREMENTAL:       "0"
						CARGO_PROFILE_DEV_DEBUG: "0"
					}
					// Cold, the workspace: clippy 3 min on 8 Mac cores (upstream's job: 15); one
					// crate's (feature-flags) 81 s on 6.
					timeout: "45m"
				}]
			}
			// As ci-rust.yml: the databases its tests read, then each package's tests on its own
			// (cargo nextest, one retry) and its doctests; kafka-assigner's grpc_integration
			// tests one at a time (showcase/scripts/rust_nextest.toml: Kafka, not upstream's
			// Redpanda, answers CreateTopics before it serves the topic). One job: ci-rust.yml bin-packs the
			// affected crates into ~8-minute shards by recorded duration (IMPROVEMENTS.md).
			// ci-rust.yml's `--run-ignored only` steps are the `test_ignored` job.
			jobs: test: {
				shards: 1
				// run_rust_tests.sh records (enact trace run, rust_footprint.py): on Linux.
				recorder: "own_linux"
				// ci-rust.yml's 4-core runner, for the tests only (fmt and lint run in the
				// 2-core preflight stage). enact sizes RAYON_NUM_THREADS and CARGO_BUILD_JOBS
				// from it.
				resources: {cpus: 4, memory_mb: 8192}
				tasks: [{
					command: "../showcase/scripts/run_rust_tests.sh {targets}"
					// A cold build and run took 53 min on Linux, 38 on macOS (each package
					// builds alone, in its own feature resolution).
					timeout: "75m"
				}]
				target_scope: {
					fallback: "none"
					rules: [{
						// The workspace's files: a test binary's footprint holds what it read
						// running and what it and the packages it links were built from
						// (showcase/scripts/rust_footprint.py), manifests and the lockfile
						// included.
						match: ["rust/**"]
						engine: "reach"
					}, {
						// The release build's helpers (the build job's): no test reads them.
						match: ["showcase/scripts/{run_rust_release_build.sh,rust_affected_crates.sh}"]
						action: "ignore"
					}]
					// Its tests are test binaries, each by its root file: a library's or binary's
					// unit tests (src/lib.rs, src/main.rs, src/bin/<x>.rs) and the integration
					// tests (tests/<x>.rs), of every workspace member (rust/<package>, or one level
					// deeper under common, deltalite and hogql).
					tests: [for dir in ["rust/*", "rust/{common,deltalite,hogql}/*"] for f in ["src/lib.rs", "src/main.rs", "src/bin/*.rs", "tests/*.rs"] {"\(dir)/\(f)"}]
					// Binaries whose every test is #[ignore]d: this job runs none of their tests
					// (test_ignored's suite).
					exclude: _rustIgnoredBinaries
					not_run: [{
						// Each boots a single-node Kubernetes (k3s) in Docker through
						// testcontainers. run_rust_tests.sh leaves these binaries out of nextest.
						tests: [
							"rust/common/k8s-awareness/tests/k3s_integration.rs",
							"rust/kafka-assigner/tests/k3s_integration.rs",
							"rust/personhog-coordination/tests/k3s_integration.rs",
						]
						reason: "needs a container runtime (k3s in Docker via testcontainers); services here run rootless under enve, without one"
					}, {
						tests: [
							"rust/feature-flags/src/bin/flags_cache_builder.rs",
							"rust/feature-flags/src/bin/warm-flags-cache.rs",
						]
						reason: "built only with its required feature, which ci-rust.yml's test job doesn't enable: cargo builds no test binary of it"
					}]
				}
			}
			// ci-rust.yml's `--run-ignored only` steps, which it runs after the package's tests in
			// the same shard: cymbal's rate_limiting tests (upstream's Redis in Docker through
			// testcontainers, here the run's Redis) and usage-ingestion's e2e, load and counters
			// tests (Kafka, ClickHouse with Django's test schema, the cluster-enabled Valkey).
			// A job of their own: a few minutes on two crates beside the full suite's 40. Its
			// tests are the files declaring them (run_rust_tests.sh's ignored_tests, each run in
			// its binary under the step's filter); recorded as the test job's are.
			jobs: test_ignored: {
				recorder: "own_linux"
				resources: {cpus: 4, memory_mb: 8192}
				// Its run, then the build's inputs (rust_footprint.py): no coverage build.
				record_resources: resources
				tasks: [{
					command: "../showcase/scripts/run_rust_tests.sh --ignored {targets}"
					timeout: "45m"
				}]
				target_scope: {
					fallback: "none"
					// As the test job's: a target's footprint holds what its binary read and was
					// built from.
					rules: [{
						match: ["rust/**"]
						engine: "reach"
					}, {
						match: ["showcase/scripts/{run_rust_release_build.sh,rust_affected_crates.sh}"]
						action: "ignore"
					}]
					tests: list.Concat([["rust/cymbal/src/modes/processing/stages/rate_limiting/limiter.rs"], _rustIgnoredBinaries])
				}
			}
			// ci-rust.yml's "Build Rust": a release build of the affected crates
			// (run_rust_release_build.sh), which upstream's determinator picks
			// (rust_affected_crates.sh runs affected-services, built in the job: select_in_job).
			// A change no crate takes (rust/bin/) builds every one, as upstream's empty affected
			// set does. One job: upstream bin-packs the crates into ~8-minute shards on 4-core
			// runners (IMPROVEMENTS.md).
			jobs: build: {
				shards:   1
				services: false
				resources: {cpus: 4, memory_mb: 8192}
				tasks: [{
					command: "../showcase/scripts/run_rust_release_build.sh {targets}"
					timeout: "90m"
				}]
				target_scope: {
					select_in_job: true
					tests:         _rustCrates
					// No build reads clippy's configuration.
					rules: list.Concat([[{match: ["clippy.toml"], action: "ignore"}], _rustCrateRules])
				}
			}
			// As ci-rust.yml's compose profiles: object storage (common-s3, hypercache,
			// kafka-deduplicator's checkpoints, batch-import-worker's buckets), etcd and
			// docker-compose.dev.yml's valkey-cluster (usage-ingestion's counters).
			uses: list.Concat([_ingestionServices, [
				{protocol: schema.#Protocol.Http, target: pipeline.services.seaweedfs},
				{protocol: schema.#Protocol.Grpc, target: pipeline.services.etcd},
				{protocol: schema.#Protocol.Redis, target: pipeline.services["valkey-cluster"]},
			]])
		}
		"hogvm": {
			name:  "hogvm"
			title: "PostHog Hog VM & Bytecode Compiler"
			technology: ["typescript", "python"]
			root: "common/hogvm"
			depends_on: ["py-root", "js-root", "build_once"]
			workspace_scope: include: ["common/hogvm", "posthog", "bin"]
			// As ci-hog.yml's filter: the VM, the HogQL compiler it runs the output of, and the
			// hog CLIs.
			watch_paths: [
				"common/hogvm/**",
				"posthog/hogql/**",
				"bin/hog",
				"bin/hoge",
				// Its TypeScript build, which every job needing its dist runs first (frontend,
				// nodejs, e2e, storybook).
				"showcase/scripts/build_hogvm.sh",
			]
			// As ci-hog.yml: the VM in Python and in TypeScript, a job each, so each runs its own
			// tests (pytest with none runs the directory, as `pytest .`). Neither runner has a
			// recorder: a recording traces each test file in a run of its own, jest's after its
			// module map is built untraced (frontend's test).
			test:     "uv run --no-sync pytest {relative_targets}"
			recorder: "trace"

			record_resources: _recordPy
			target_scope: tests: ["common/hogvm/python/**/test_*.py"]
			jobs: test_typescript: {
				name:     "Test (TypeScript)"
				recorder: "trace"

				record_resources: _recordJs
				recorded_by: ["enact-node"]
				tasks: [
					{name: "Warm jest", command: "pnpm --dir typescript test --listTests >/dev/null"},
					{name: "Run Tests", command: "pnpm --dir typescript test {relative_targets}"},
				]
				target_scope: tests: ["common/hogvm/typescript/src/**/*.test.ts"]
			}
		}
		"nodejs": {
			name:       "nodejs"
			title:      "PostHog Node.js Ingestion & Plugin Server"
			// Python too: its runner runs the backend's venv (the Django template's bootstrap,
			// setup_test_environment, the Kafka topics), so its prepare installs both.
			technology: ["typescript", "python"]
			root:       "nodejs"
			// Its builds compile in the Rust workspace: turbo's prepare builds the
			// replay-anonymizer napi addon (`cargo build --release`), rust_ingestion_e2e the
			// ingestion consumer; CI restores and saves their rust/target cache.
			cargo: workspace: "rust"
			// proto/: ingestion-worker-proto's build script compiles it (rust_ingestion_e2e).
			depends_on: ["js-root", "test_env", "proto", "test_quarantine", "build_once"]
			workspace_scope: include: list.Concat([_djangoTree, ["nodejs", "rust", "proto", "frontend/src/types.ts", "docker", "infra"]])
			// As ci-nodejs.yml's filter, and its rust one: a change affecting ingestion-consumer
			// (RUST_NODE_E2E_CRATES, by affected-services' determinator) runs every job, as a
			// change to it or to a workspace crate it builds from, or one marking every crate.
			watch_paths: list.Concat([[
				"rust/ingestion-consumer/**",
				"rust/ingestion-worker-proto/**",
				"rust/common/{alloc,continuous_profiling,k8s-awareness,kafka-consumer,lifecycle,liveness}/**",
				"nodejs/**",
				"common/replay-headless/**",
				// What replay-headless's dist (the rasterizer's ./protocol) is bundled from.
				"common/replay-shared/src/**",
				"common/replay-shared/package.json",
				"common/plugin_transpiler/**",
				"rust/replay-anonymizer/**",
				"rust/replay-anonymizer-node/**",
				"rust/common/hogvm/**",
				// HogVM's sources and its build's configs: the tests load its dist.
				"common/hogvm/typescript/src/**",
				"common/hogvm/typescript/{package.json,tsconfig.json,tsconfig.build.json}",
				"rust/common/ingestion_warnings/*.json",
				// The workflow refreshing the AI cost tables, which a cost test checks.
				".github/workflows/update-ai-costs.yml",
				"posthog/clickhouse/**",
				"posthog/plugins/**",
				"posthog/cdp/filter_globals.json",
				"showcase/scripts/run_nodejs_tests.sh",
				// The Rust jobs' build settings the ingestion e2e's consumer builds with.
				"showcase/scripts/rust_ci_env.sh",
				// The maildev service only this suite starts (its lockfile and installer).
				"infra/maildev/**",
			], _rustWorkspaceEveryCrate, _djangoMigrations])
			// ci-nodejs.yml's format:check and lint (prettier; eslint, then oxlint with the
			// package's .oxlintrc.nodejs.json), on the package's own changed sources: its watch
			// paths take in Rust crates and Django files too, which the tools reject from here.
			jobs: fmt: {
				services: false
				tasks: [{
					command: "pnpm exec prettier --check --ignore-unknown --no-error-on-unmatched-pattern {relative_changed_files}"
					filter: include: ["nodejs/**"]
				}]
			}
			jobs: lint: {
				services: false
				tasks: [{
					command: "pnpm exec eslint {relative_changed_files} && pnpm exec oxlint -c .oxlintrc.nodejs.json --no-error-on-unmatched-pattern {relative_changed_files}"
					filter: include: ["nodejs/**/*.{ts,tsx,js,mjs,cjs}"]
				}]
			}
			// As ci-nodejs.yml's build job: turbo's prepare builds the workspace packages it
			// imports (@posthog/hogvm, @posthog/replay-anonymizer) first, under the test shards'
			// lock and turbo cache key (run_nodejs_tests.sh); tsc finds no module without them.
			build: "cd .. && showcase/scripts/build_hogvm.sh && showcase/scripts/exclusive.sh nodejs-build bin/turbo --filter=@posthog/nodejs prepare && pnpm --filter=@posthog/nodejs build"
			// As ci-nodejs.yml's tests job: its test databases and build, then both jest lanes,
			// in its three shards, each given its share of the selected test files (a run with
			// none: the runner passes ENACT_SHARD_* to jest's --shard). Each shard runs jest in an
			// enve service instance of its own (Postgres, Redis, ClickHouse, Kafka); the run's
			// serve the Django template its database clones, which a cache miss builds through a
			// pytest session that sets ClickHouse up too. A recording traces each test file in a
			// jest of its own on the shard's instance, set up once (the runner's recorder, Linux).
			jobs: test: {
				name:     "Test"
				recorder: "own_linux"
				recorded_by: ["enact-node"]
				shards: 3
				// A shard is jest's 4 workers (upstream's --maxWorkers=4) on a service instance
				// of its own: undeclared, three shards packed into one tonky-ci slot, and the
				// host's memory ran out with shard 1 at 5.0 GB. Asked with a fifth more.
				resources: {cpus: 4, memory_mb: 6144}
				// A shard's jest runs ~10 min here (ci-nodejs.yml's tests job: 45 min), and a
				// cold shard bootstraps the Django template first (see base's test): the default
				// step limit, 600 s without recorded durations, killed every shard mid-suite.
				tasks: [{
					name:    "Run Tests"
					command: "../showcase/scripts/run_nodejs_tests.sh {targets}"
					timeout: "90m"
				}]
			}
			// The lanes' files: both scripts ignore postgres-parity, service-e2e and dev/.
			target_scope: {
				tests: ["nodejs/{src,tests}/**/*.test.ts"]
				// rust_ingestion_e2e's.
				exclude: ["nodejs/tests/service-e2e/rust-ingestion-consumer.serial.test.ts"]
				not_run: [{
					tests: ["nodejs/**/*postgres-parity*.test.ts"]
					reason: "ci-nodejs.yml's postgres-parity step (continue-on-error, on an isolated persons database) isn't modeled"
				}, {
					tests: ["nodejs/tests/service-e2e/personhog-shadow-parity.serial.test.ts"]
					reason: "no upstream workflow runs it (the lanes ignore service-e2e)"
				}, {
					tests: ["nodejs/{src,tests}/**/dev/**"]
					reason: "dev-only scripts and benchmarks, never CI tests (jest.config.shared.js)"
				}]
			}
			// ci-nodejs.yml's "Rust ingestion consumer Node API e2e": the debug build of
			// ingestion-consumer, then the jest e2e running it (`cargo run`) against two Node
			// ingestion API workers (tsx), on an enve instance of its own as a test shard's
			// (run_nodejs_tests.sh --rust-ingestion-e2e; patches/0007 points the test at it).
			jobs: rust_ingestion_e2e: {
				shards: 1
				target_scope: tests: ["nodejs/tests/service-e2e/rust-ingestion-consumer.serial.test.ts"]
				resources: {cpus: 4, memory_mb: 8192}
				// The e2e traced, then the consumer's build inputs (rust_footprint.py): on Linux.
				recorder: "own_linux"
				// Its run's size: no coverage build.
				record_resources: resources
				tasks: [{
					command: "../showcase/scripts/run_nodejs_tests.sh --rust-ingestion-e2e {targets}"
					timeout: "45m"
				}]
			}
			uses: [
				{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres},
				{protocol: schema.#Protocol.Http, target: pipeline.services.clickhouse},
			]
		}
		"livestream": {
			name:       "livestream"
			title:      "PostHog Livestream & Realtime Event Gateway"
			technology: "go"
			root:       "livestream"
			depends_on: ["root"]
			workspace_scope: include: ["livestream", "products/web_analytics"]
			watch_paths: ["livestream/**", "showcase/scripts/run_go_tests.sh"]
			lint: _golangciLint
			// The root package, as ci-livestream.yml (run_go_tests.sh: the selected tests). Go
			// has no recorder: a recording traces each test in a run of its own (Linux).
			test:     "../showcase/scripts/run_go_tests.sh --all . {targets}"
			recorder: "trace"

			record_resources: _recordGo
			target_scope: {
				tests: ["livestream/**/*_test.go"]
				not_run: [{
					tests: ["livestream/*/**/*_test.go"]
					reason: "ci-livestream.yml runs the root package's tests only (`go test -v`): events' TestSessionStats_CleanupEmptyCounters fails on every run (TTL eviction timing)"
				}]
				rules: [{match: ["livestream/**"], engine: "reach"}]
			}
		}
		"proto": {
			name:       "proto"
			title:      "PostHog Protocol Buffers & Schema Definitions"
			technology: "protobuf"
			root:       "proto"
			depends_on: ["root"]
			workspace_scope: include: ["bin"]
			watch_paths: [
				"proto/**",
				"packages/personhog-proto/**",
				"bin/generate_personhog_proto.sh",
			]
			lint: "buf lint proto/ && buf breaking proto/ --against '../.git#ref=HEAD,subdir=proto' && UV_PROJECT_ENVIRONMENT=.enact/state/proto-venv uv sync --frozen --no-install-project --only-group proto-codegen && PATH=\"$(realpath ../.enact/state/proto-venv)/bin:$PATH\" bash ../bin/generate_personhog_proto.sh && git add -N ../packages/personhog-proto/ && git diff --exit-code -- ../packages/personhog-proto/"
		}
		// Upstream's own CI: its workflows, actions and runner configuration. Its lint is
		// ci-actionlint.yml's (showcase/scripts/actionlint.sh), over every workflow, enact's
		// generated ci.yml too.
		"workflows": {
			name:       "workflows"
			title:      "GitHub Actions Workflows & Actionlint"
			technology: "yaml"
			root:       "."
			depends_on: ["root"]
			watch_paths: [
				".github/*",
				".github/{actions,workflows,pr-deploy}/**",
				".github/scripts/flatten-parallel-steps-for-actionlint.awk",
				".depot/**",
				"depot.json",
				"tools/workflow-plan/**",
				"showcase/scripts/actionlint.sh",
			]
			workspace_scope: include: [".depot", "tools/workflow-plan"]
			lint: "./showcase/scripts/actionlint.sh"
		}
		"mcp": {
			name:       "mcp"
			title:      "PostHog MCP AI Server & Toolchain"
			technology: "typescript"
			root:       "services/mcp"
			// quill's build need not run first (simulate's INTER_COMPONENT_BUILD_ORDER_HAZARD
			// info): the test and typecheck jobs start with its `pnpm build`
			// (build_mcp_ui_apps.sh), which builds the quill packages; fmt and lint read sources
			// only.
			depends_on: ["js-root", "quill", "vitest_marker"]
			workspace_scope: include: [
				".config",
				"common/mosaic",
				"services/mcp",
				"packages/llm-normalizer",
				"products",
				"frontend/src/mocks",
				"frontend/src/taxonomy",
				"frontend/bin",
			]
			watch_paths: [
				"services/mcp/**",
				"products/*/mcp/**",
				"packages/llm-normalizer/**",
				"packages/quill/**",
				"common/mosaic/**",
				".config/.markdownlint-cli2.jsonc",
				// The recipe examples the parser reference tool loads (copy-instructions.ts).
				"products/ai_observability/backend/prompts/parser_recipe_examples.yaml",
				// The agent skills and UI apps the server ships.
				"products/*/skills/**",
				"products/{actions,ai_observability,cohorts,error_tracking,experiments,feature_flags,product_analytics,replay,replay_vision,surveys,tasks,tracing,visual_review,workflows}/apps/**",
				// What the UI apps import (ci-mcp.yml's mcp-typescript and ci-mcp-ui-apps.yml's filters).
				"products/notebooks/**",
				"products/product_analytics/frontend/insights/**",
				"products/*/frontend/generated/**",
				"frontend/src/mocks/fixtures/**",
				"showcase/scripts/check_mcp_ui_apps.sh",
				"showcase/scripts/build_mcp_ui_apps.sh",
			]
			fmt:  "pnpm exec oxfmt --check \"./**/*.{md,mdx}\" \"./**/*.{yaml,yml}\""
			lint: "pnpm exec oxlint --quiet . && pnpm exec markdownlint-cli2 --config ../../.config/.markdownlint-cli2.jsonc \"./**/*.{md,mdx}\""
			// ci-mcp.yml's unit tests (vitest's workers parallelise them), then its Hono tests
			// (vitest.hono.config.mts), a job each: each config runs its own files only. As
			// there, `pnpm build` first (build_mcp_ui_apps.sh: the quill packages, then the UI
			// apps into public/, which the workers pool reads, as the UI-app snapshots do quill's
			// dist, once per source state for the mcp jobs side by side) and the instructions
			// the server imports, in a task of their own. vitest takes test files as filters. A
			// recording traces each test file in a run of its own, with the functions it ran in
			// Node (vitest.sh's marker ends each file's record; the workers project's tests run in
			// workerd, which reach their files whole).
			jobs: test: {
				name:     "Test"
				shards:   1
				recorder: "trace"
				recorded_by: ["enact-node"]
				needs: _mcpUiAppsNeeds
				tasks: [
					{name: "Build", command: _mcpPrebuild},
					{name: "Run Tests", command: "../../.enact/vitest/vitest.sh run {relative_targets}"},
				]
			}
			// vitest.config.mts' unit and workers projects: the integration tests are
			// mcp_integration's, the Hono tests test_hono's.
			target_scope: {
				tests: ["services/mcp/tests/**/*.test.ts"]
				exclude: ["services/mcp/tests/**/*.integration.test.ts", "services/mcp/tests/hono/**"]
				not_run: [{
					tests: ["services/mcp/tests/live/**"]
					reason: "test:live checks the live context-mill manifest over the network (ci-mcp-live-canary.yml, scheduled)"
				}]
			}
			jobs: test_hono: {
				name:     "Test (Hono)"
				recorder: "trace"
				recorded_by: ["enact-node"]
				needs: _mcpUiAppsNeeds
				tasks: [
					{name: "Build", command: _mcpPrebuild},
					{name: "Run Tests", command: "../../.enact/vitest/vitest.sh run --config vitest.hono.config.mts {relative_targets}"},
				]
				target_scope: tests: ["services/mcp/tests/hono/**/*.test.ts"]
			}
			// As ci-mcp.yml's "Type check (tsgo)", after its build.
			jobs: typecheck: {
				direct: true
				resources: {cpus: 2.0, memory_mb: 4096}
				needs: _mcpUiAppsNeeds
				tasks: [{command: "../../showcase/scripts/build_mcp_ui_apps.sh && pnpm typecheck"}]
			}
			// The UI apps (build_mcp_ui_apps.sh), once per source state, after quill's dist
			// (`needs`): CI builds them in a job of its own, which the jobs starting with them
			// restore with quill's dist, finding both current.
			jobs: ui_apps: {
				services: false
				needs: ["quill:build"]
				// quill's and the UI apps' vite builds peak at 2.3 GB.
				resources: {cpus: 2.0, memory_mb: 3072}
				outputs: {
					paths: ["services/mcp/public/ui-apps"]
					key: list.Concat([[
						"services/mcp/**",
						"products/**",
						"packages/quill/**",
						"frontend/src/**",
						"showcase/scripts/build_mcp_ui_apps.sh",
					], _buildOnceKey])
				}
				tasks: [{command: "../../showcase/scripts/build_mcp_ui_apps.sh"}]
			}
			// ci-mcp.yml's Build Package checks of what is generated and named: the tool-inputs
			// schema (hogli build:schema-mcp's command), the generated UI apps, the tool names.
			jobs: schema_check: {
				services: false
				tasks: [{
					name:    "Check MCP schema is up to date"
					command: "pnpm exec tsx scripts/generate-tool-schema.ts && pnpm exec oxfmt schema/tool-inputs.json && git diff --exit-code schema/tool-inputs.json"
				}, {
					name:    "Check generated UI apps are up to date"
					command: "pnpm run generate:ui-apps && git diff --exit-code -- src/ui-apps/apps/generated/ src/resources/ui-apps.generated.ts"
				}, {
					name:    "Lint tool names"
					command: "pnpm lint-tool-names"
				}]
			}
			// ci-mcp-ui-apps.yml: the UI apps built and each one's bundle there.
			jobs: build: {
				services: false
				tasks: [{
					command: "../../showcase/scripts/check_mcp_ui_apps.sh"
					filter: include: _mcpUiAppsFiles
				}]
			}
		}
		// What boots a live PostHog for both live stacks (e2e, mcp_integration): live_posthog.sh
		// and the Celery queues it starts the worker with. The stacks' runners call it with the
		// test databases (test_env) and the GeoIP database (geoip). It runs no tests and the
		// live stacks depend on it through their runners: their harness, left out of their
		// footprints' digests and age, while a change to it still runs both suites whole (their
		// footprints hold it).
		"live_harness": {
			name:       "live_harness"
			title:      "Live PostHog stack"
			// Not rust: the stacks build their Rust services in rust/'s workspace (their own
			// `cargo: workspace`); a Rust technology at the root would declare one there.
			technology: ["python", "typescript"]
			root:       "."
			depends_on: ["test_env", "geoip"]
			watch_paths: [
				"showcase/scripts/live_posthog.sh",
				// The Rust jobs' build settings its Rust services build with.
				"showcase/scripts/rust_ci_env.sh",
				"bin/celery-queues.env",
			]
		}
		// e2e's runner (run_e2e_tests.sh) and its builds (build_e2e.sh): e2e's harness, as
		// live_harness is.
		"e2e_harness": {
			name:       "e2e_harness"
			title:      "Playwright E2E runner"
			technology: ["python", "typescript"]
			root:       "."
			depends_on: ["live_harness", "build_once"]
			watch_paths: [
				"showcase/scripts/run_e2e_tests.sh",
				"showcase/scripts/build_e2e.sh",
			]
		}
		// ci-e2e-playwright.yml's "Playwright E2E tests": a whole PostHog booted for end-to-end
		// testing on the run's services (the frontend built, Django, Celery, the Temporal worker,
		// personhog, Rust capture and capture-ai behind a proxy, and the Node.js ingestion) and
		// Playwright's chromium from the env's store driving it (run_e2e_tests.sh). Judged by
		// playwright's exit code.
		"e2e": {
			name:       "e2e"
			title:      "PostHog Playwright End-to-End Suite"
			technology: ["typescript", "python", "rust"]
			root:       "."
			// Builds capture and personhog in the Rust workspace's target dir, as mcp_integration.
			cargo: workspace: "rust"
			// proto/: personhog's and capture's build scripts compile it.
			depends_on: ["base", "products", "frontend", "proto", "e2e_harness"]
			workspace_scope: include: list.Concat([_djangoTree, [
				"playwright",
				"frontend",
				"packages",
				"services/mcp/src/ui-apps",
				"nodejs",
				"rust",
				"proto",
				"docker",
				"infra",
			]])
			tags: ["e2e", "playwright"]
			watch_paths: list.Concat([[
				"playwright/**",
				"products/*/frontend/e2e/**",
				"tools/playwright_spec_selection.py",
				"tools/playwright_area_map.json",
				"tools/test_playwright_spec_selection.py",
				"rust/persons_migrations/**",
				"showcase/scripts/live_footprint.py",
				"showcase/scripts/rust_footprint.py",
				"showcase/scripts/node_reads.mjs",
			], _liveCaptureRust, _liveIngestionNode])
			// Upstream: one job (no shards since #46853), 6 Playwright and 4 granian workers on
			// depot-ubuntu-24.04-8, 45 minutes. Here a tonky-ci slot, 6 CPUs and what its 13 GB
			// leave usable: run_e2e_tests.sh scales both worker counts to the job's CPUs.
			// The builds (build_e2e.sh) run in a task of their own, before the tests': the
			// frontend's build:products rewrites the tracked frontend/src/products.tsx,
			// productScenes.tsx and products.json as committed, and a rewrite while the tests'
			// task runs keeps their footprints out.
			jobs: test: {
				worker: "standard"
				// run_e2e_tests.sh records (live_footprint.py).
				recorder:  "own"
				shards:    1
				resources: {cpus: 6, memory_mb: 11264}
				// The frontend's dist, built once (_frontendBuild) and restored.
				needs: ["frontend:build"]
				tasks: [{
					name:    "Build"
					command: _frontendBuild + " && showcase/scripts/build_e2e.sh"
					timeout: "30m"
				}, {
					name:    "Run Tests"
					command: "showcase/scripts/run_e2e_tests.sh {targets}"
					timeout: "60m"
				}]
				// playwright.config.ts's testMatch. A spec's own change, or a page model or
				// helper it imports, runs the specs reaching it (upstream's selection maps areas
				// to specs). The app's code runs the specs whose footprints hold it
				// (live_footprint.py: the bundle's sources by the build's metafiles, the Python
				// the app restarted for each spec read) and those not traced; anything else of
				// the component runs every spec.
				target_scope: {
					fallback: "all"
					tests: [
						"playwright/e2e/**/*.spec.ts",
						"products/*/frontend/e2e/**/*.spec.ts",
					]
					rules: [{
						match: [
							"playwright/**/*.ts",
							"products/*/frontend/e2e/**/*.ts",
							"frontend/src/**/*.{ts,tsx,js,jsx,mjs}",
							"products/*/frontend/**/*.{ts,tsx,js,jsx}",
							"ee/frontend/**/*.{ts,tsx,js,jsx}",
						]
						engine:      "typescript"
						granularity: "file"
					}, {
						match: ["posthog/**/*.py", "ee/**/*.py", "common/**/*.py", "products/**/*.py"]
						engine:      "python"
						granularity: "file"
					}, {
						match:  _liveIngestionNodeTests
						action: "ignore"
					}]
				}
			}
			// compose's db, redis7, kafka, clickhouse, objectstorage and (the temporal profile)
			// temporal, as the job starts them.
			uses: [
				{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres},
				{protocol: schema.#Protocol.Redis, target: pipeline.services.redis},
				{protocol: schema.#Protocol.Kafka, target: pipeline.services.kafka},
				{protocol: schema.#Protocol.Http, target: pipeline.services.clickhouse},
				{protocol: schema.#Protocol.Http, target: pipeline.services.seaweedfs},
				{protocol: schema.#Protocol.Grpc, target: pipeline.services.temporal},
			]
		}
		"tooling": {
			name:       "tooling"
			title:      "PostHog Developer Tooling & Hogli Framework"
			technology: "python"
			root:       "tools/hogli-commands"
			// geoip: hogli's tool:download-mmdb runs its installer.
			depends_on: ["py-root", "geoip"]
			workspace_scope: include: [
				"devenv",
				".depot",
				".semgrep",
				"frontend/package.json",
				"services/mcp/tsconfig.json",
			]
			watch_paths: [
				"tools/hogli-commands/**",
				"tools/hogli/**",
				"hogli.yaml",
				// The intents `hogli devenv` reads.
				"devenv/**",
				// bin/'s own files but the live stack's Celery queues (live_harness) and the
				// GeoIP installer (geoip): a file upstream adds under bin/ce*, bin/dow* or
				// bin/download-m* is unowned until listed (the coverage audit names it).
				"bin/[!cd]*",
				"bin/c[!e]*",
				"bin/d[!o]*",
				"bin/do[!w]*",
				"bin/download-[!m]*",
				"bin/{helpers,sandbox-shims,test}/**",
			]
			// From the repository root, as ci-python.yml runs them: the tests expect its paths.
			// Its pytest runs outside the Django project (no recorder plugin): a recording traces
			// each test file in a run of its own. hogli writes the user's home (its telemetry
			// and hints config, gh's state; devbox:setup's tests install mutagen there and start
			// its daemon): the tests get a HOME of their own (`_ownHome`), which ends the daemon.
			test:     "cd ../.. && \(_ownHome) uv run --no-sync pytest {targets}"
			recorder: "trace"

			record_resources: _recordPy
			target_scope: {
				tests: ["tools/hogli-commands/hogli_commands/tests/**/test_*.py"]
				default_target: "tools/hogli-commands/hogli_commands/tests"
			}
		}
	}
}

// frontend:typecheck's tsgo state: rolling (no `key`), so each run restores the newest entry
// and a passing default-branch run saves one per commit. Seeded: a run restoring nothing fails
// "Cache seed needed" instead of checking the whole program cold. The seed is a manual
// `seed_caches` dispatch, no cron: an automated run never does a cold full check.
pipeline: caches: "frontend-tsgo": {
	name: "frontend tsgo declaration-emit cache"
	paths: [_tsgoCache]
	seed: {}
	used_by: {
		components: ["frontend"]
		jobs: [pipeline.#jobs.typecheck]
	}
}

// products:typecheck's mypy cache (`--cache-fine-grained`), rolling and seeded as
// frontend-tsgo is: a run restoring nothing fails "Cache seed needed", never checks cold.
pipeline: caches: mypy: {
	name: "mypy fine-grained cache"
	paths: [".mypy_cache"]
	seed: {}
	used_by: {
		components: ["products"]
		jobs: [pipeline.#jobs.typecheck]
	}
}
