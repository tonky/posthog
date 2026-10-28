package replay

import (
	"list"

	"enact.dev/schema"
)

// The plugin server (nodejs/) by area, as its TypeScript import graph splits it (tsc's module
// resolution with tsconfig `paths`, dynamic `import()` and `jest.mock` names included; the
// overlay test nodejs_split.rs checks it): a component's tests import only its own files
// and its dependencies', so a change selects every suite whose tests reach it. The areas sit
// on nodejs_base: src/common, the top-level sources, the shared test helpers and fixtures,
// the package's configs, and the area files common imports (configs, schemas, types). An
// area's suite runs the upstream jest lanes on its own test files (run_nodejs_tests.sh), as
// ci-nodejs.yml's tests job runs all of them. `nodejs`, the leaf depending on every area,
// keeps ci-nodejs.yml's format, lint and build (tsc, the only typecheck: ts-jest compiles
// with isolatedModules) and the Rust ingestion consumer's e2e.
//
// A test whose imports reach a dependent's area runs in that dependent's suite
// (`handoff`): the api router's, the hog transformer's and the ingestion e2e suites import
// the servers.

// Every suite's cone: its runner clones the Django template and builds the workspace
// packages (turbo's prepare builds the replay-anonymizer napi addon in the Rust workspace).
// frontend/public/services: the segment templates' test checks each one's icon there.
_nodejsCone: list.Concat([_djangoTree, ["nodejs", "rust", "proto", "frontend/public/services", "docker", "infra"]])

_nodejsServices: [
	{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres},
	{protocol: schema.#Protocol.Http, target: pipeline.services.clickhouse},
]

// An area: its test job runs ci-nodejs.yml's jest lanes on its share of the area's selected
// test files, a shard per enve service instance (Postgres, Redis, ClickHouse, Kafka; the
// run's Postgres serves the Django template's clone, which a cache miss builds through a
// pytest session that sets ClickHouse up too). A recording traces each test file it wants
// in a jest of its own on the shard's instance, set up once (the runner's recorder, Linux).
_nodejsArea: {
	// Python too: the runner runs the backend's venv (the Django template's bootstrap,
	// setup_test_environment, the Kafka topics), so its prepare installs both.
	technology: ["typescript", "python"]
	// The repository: the runner and its targets are the checkout's paths.
	root: "."
	cargo: workspace: "rust"
	// Its cone is nodejs_env's (include_dependencies).
	jobs: test: {
		name:     "Test"
		recorder: "own_linux"
		recorded_by: ["enact-node"]
		// A shard is jest's 4 workers (upstream's --maxWorkers=4) on a service instance of
		// its own: three undeclared shards packed into one tonky-ci slot ran its memory out
		// with one at 5.0 GB. Asked with a fifth more.
		resources: {cpus: 4, memory_mb: 6144}
		// A cold shard bootstraps the Django template first (see base's test): the default
		// step limit, 600 s without recorded durations, killed shards mid-suite.
		tasks: [{
			name:    "Run Tests"
			command: "showcase/scripts/run_nodejs_tests.sh {targets}"
			timeout: "90m"
		}]
	}
	uses: _nodejsServices
}

pipeline: components: {
	// What the suites run in, outside nodejs/: the runner, the Django template it clones (the
	// migrations), the workspace packages turbo's prepare builds and the data the tests
	// check. Its cone is every area's (theirs include nothing of their own): a repository-
	// rooted component's cone audit checks the files it includes, and the Django tree's
	// TypeScript and tests are none the suites run. No jobs.
	"nodejs_env": {
		name:  "nodejs_env"
		title: "PostHog Node.js suites' environment"
		// No ecosystem's sources of its own: the areas' are nodejs/'s.
		technology: "shell"
		root:       "."
		depends_on: ["js-root", "test_env", "test_quarantine", "build_once"]
		workspace_scope: include: _nodejsCone
		watch_paths: list.Concat([[
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
			"posthog/clickhouse/**",
			"posthog/plugins/**",
			"posthog/cdp/filter_globals.json",
			"showcase/scripts/run_nodejs_tests.sh",
			// The maildev service only these suites start (its lockfile and installer).
			"infra/maildev/**",
		], _rustWorkspaceEveryCrate, _djangoMigrations])
	}
	// What every area imports or runs with: src/common and the top-level sources, the test
	// helpers no area owns, the fixtures, the package's configs and jest setup, and the
	// area files src/common's config and hub import.
	"nodejs_base": _nodejsArea & {
		name:  "nodejs_base"
		title: "PostHog Node.js shared core (common, helpers, configs)"
		depends_on: ["nodejs_env"]
		watch_paths: [
			"nodejs/*",
			"nodejs/{assets,bin,sql}/**",
			"nodejs/src/*.yaml",
			"nodejs/src/{capabilities,lifecycle,plugin-scaffold,types}.ts",
			"nodejs/src/common/**",
			// Imported by src/common (config/config.ts, hub.ts, the producers).
			"nodejs/src/ai-observability/config.ts",
			"nodejs/src/cdp/{config,types}.ts",
			"nodejs/src/cdp/outputs/producers.ts",
			"nodejs/src/cdp/schema/{cyclotron,hogflow,pushNotification}.ts",
			"nodejs/src/cdp/services/managers/integration-manager.service.ts",
			"nodejs/src/cdp/utils/{encryption-utils,jwt-utils}.ts",
			"nodejs/src/logs/config.ts",
			"nodejs/src/logs/outputs/producers.ts",
			"nodejs/src/servers/base-server.ts",
			"nodejs/tests/{config,utils}.test.ts",
			"nodejs/tests/{assets,fixtures,utils}/**",
			"nodejs/tests/helpers/{clickhouse,database-guard,database-guard.test,event-headers,expectations,hog-invocation-results,kafka-message,kafka,metrics,mock-ingestion-outputs,person,pipeline-event,plugin-event,promises,raw-event,redis,service-process,snapshots,snapshots.test,sql,team,tls,truth}.ts",
			"nodejs/tests/helpers/mocks/{consumer.mock,date.mock,producer.mock,producer.spy,request.mock}.ts",
		]
		jobs: test: shards: 1
		target_scope: {
			tests: [
				"nodejs/src/common/**/*.test.ts",
				"nodejs/tests/{config,utils}.test.ts",
				"nodejs/tests/{helpers,utils}/**/*.test.ts",
			]
			handoff: [{
				to: "nodejs_replay"
				// They import session replay's consumer and recording API.
				tests: ["nodejs/src/common/kafka/consumer/consumer-v2.test.ts", "nodejs/src/common/utils/request-http2.test.ts"]
			}, {
				to: "nodejs_servers"
				tests: ["nodejs/src/common/api/router.test.ts"]
			}]
			not_run: [{
				tests: ["nodejs/src/common/personhog/personhog-postgres-parity.serial.test.ts"]
				reason: "ci-nodejs.yml's postgres-parity step (continue-on-error, on an isolated persons database) isn't modeled"
			}]
		}
	}
	// The ingestion framework and the steps every pipeline shares, which session replay's
	// pipeline builds on too, with the pipelines' configs src/ingestion/config.ts imports.
	"nodejs_ingestion_core": _nodejsArea & {
		name:  "nodejs_ingestion_core"
		title: "PostHog Node.js ingestion framework & common steps"
		depends_on: ["nodejs_base"]
		watch_paths: [
			"nodejs/src/ingestion/{framework,common}/**",
			"nodejs/src/ingestion/config.ts",
			"nodejs/src/ingestion/pipelines/sessionreplay/{config,constants}.ts",
			"nodejs/src/ingestion/pipelines/sessionreplay/shared/constants.ts",
			"nodejs/src/ingestion/pipelines/sessionreplay/shared/outputs/producer-config.ts",
			"nodejs/src/ingestion/pipelines/errortracking/config.ts",
			"nodejs/src/ingestion/pipelines/metrics/config.ts",
			"nodejs/src/ingestion/pipelines/metrics/outputs/producers.ts",
			"nodejs/tests/ingestion/{framework,common}/**",
			"nodejs/tests/helpers/{ingestion-e2e,mock-pipeline,tophog}.ts",
		]
		jobs: test: shards: 1
		target_scope: {
			tests: [
				"nodejs/src/ingestion/{framework,common}/**/*.test.ts",
				"nodejs/tests/ingestion/{framework,common}/**/*.test.ts",
			]
			handoff: [{
				to: "nodejs_ingestion"
				tests: ["nodejs/tests/ingestion/framework/batching-pipeline.integration.test.ts"]
			}, {
				to: "nodejs_servers"
				tests: ["nodejs/src/ingestion/common/steps/event-processing/hog-transform-event-step.test.ts"]
			}]
		}
	}
	// The event pipelines (analytics, AI, client warnings, error tracking, heatmaps,
	// metrics), the ingestion API and the doctor.
	"nodejs_ingestion": _nodejsArea & {
		name:  "nodejs_ingestion"
		title: "PostHog Node.js event ingestion pipelines"
		depends_on: ["nodejs_ingestion_core"]
		watch_paths: [
			"nodejs/src/ingestion/*.ts",
			"nodejs/src/ingestion/{__snapshots__,api,doctor}/**",
			"nodejs/src/ingestion/pipelines/{ai,analytics,clientwarnings,errortracking,heatmaps,metrics}/**",
			"nodejs/tests/ingestion/*.ts",
			"nodejs/tests/ingestion/pipelines/{clientwarnings,heatmaps}/**",
			"nodejs/tests/service-e2e/personhog-shadow-parity.serial.test.ts",
			"nodejs/tests/helpers/ingestion-outputs.ts",
			// The workflow refreshing the AI cost tables, which the costs script's test checks.
			".github/workflows/update-ai-costs.yml",
		]
		jobs: test: shards: 1
		target_scope: {
			tests: [
				"nodejs/src/ingestion/*.test.ts",
				"nodejs/src/ingestion/{api,doctor}/**/*.test.ts",
				"nodejs/src/ingestion/pipelines/{ai,analytics,clientwarnings,errortracking,heatmaps,metrics}/**/*.test.ts",
				"nodejs/tests/ingestion/*.test.ts",
				"nodejs/tests/ingestion/pipelines/{clientwarnings,heatmaps}/**/*.test.ts",
				"nodejs/tests/service-e2e/personhog-shadow-parity.serial.test.ts",
			]
			handoff: [{
				to: "nodejs_servers"
				tests: [
					"nodejs/src/ingestion/ingestion-consumer.serial.test.ts",
					"nodejs/tests/ingestion/{flag-evaluations-e2e,ingestion-e2e,person-properties-metadata.e2e,person-updates-e2e}.test.ts",
				]
			}]
			// The lanes' scripts ignore postgres-parity and service-e2e.
			not_run: [{
				tests: ["nodejs/tests/ingestion/postgres-parity.test.ts"]
				reason: "ci-nodejs.yml's postgres-parity step (continue-on-error, on an isolated persons database) isn't modeled"
			}, {
				tests: ["nodejs/tests/service-e2e/personhog-shadow-parity.serial.test.ts"]
				reason: "no upstream workflow runs it (the lanes ignore service-e2e)"
			}]
		}
	}
	// Session replay: its ingestion pipeline, the recording API and the replay tooling.
	"nodejs_replay": _nodejsArea & {
		name:  "nodejs_replay"
		title: "PostHog Node.js session replay"
		depends_on: ["nodejs_ingestion_core"]
		watch_paths: [
			"nodejs/src/session-replay/**",
			"nodejs/src/ingestion/pipelines/sessionreplay/**",
			"nodejs/tests/session-replay/**",
			"nodejs/tests/ingestion/pipelines/sessionreplay/**",
			"nodejs/tests/helpers/ml-mirror-staged-batch.ts",
		]
		jobs: test: shards: 2
		target_scope: {
			tests: [
				"nodejs/src/session-replay/**/*.test.ts",
				"nodejs/src/ingestion/pipelines/sessionreplay/**/*.test.ts",
				"nodejs/tests/session-replay/**/*.test.ts",
				"nodejs/tests/ingestion/pipelines/sessionreplay/**/*.test.ts",
			]
			not_run: [{
				tests: ["nodejs/src/ingestion/pipelines/sessionreplay/ml-mirror-image-scrub-sidecar/**"]
				reason: "a package of its own the plugin server's jest leaves out (modulePathIgnorePatterns), and no upstream workflow runs its jest"
			}]
		}
	}
	// CDP (destinations, transformations, workflows, the hog executor) with AI observability
	// (its five tests import CDP), and the log pipeline modules CDP's API imports.
	"nodejs_cdp": _nodejsArea & {
		name:  "nodejs_cdp"
		title: "PostHog Node.js CDP & AI observability"
		depends_on: ["nodejs_base"]
		watch_paths: [
			"nodejs/src/{cdp,ai-observability}/**",
			"nodejs/src/logs/{attribute-value,ingestion-otel-metrics,log-body-parse,log-pii-scrub,log-record-avro,log-record-size}.ts",
			"nodejs/src/logs/metrics-rules/{compile-metric-rules,tally}.ts",
			"nodejs/src/logs/pipeline/log-processing-pipeline.ts",
			"nodejs/src/logs/sampling/{compile-rules,evaluate,filter-group-match,property-filter-match}.ts",
			"nodejs/src/logs/transformations/hog-log-exec.ts",
			"nodejs/tests/helpers/cdp.ts",
			"nodejs/tests/helpers/mocks/job-queue.mock.ts",
		]
		jobs: test: shards: 2
		target_scope: {
			tests: ["nodejs/src/{cdp,ai-observability}/**/*.test.ts"]
			handoff: [{
				to: "nodejs_servers"
				tests: ["nodejs/src/cdp/hog-transformations/hog-transformer.service.test.ts"]
			}]
			not_run: [{
				tests: ["nodejs/src/cdp/dev/**"]
				reason: "dev-only scripts and benchmarks, never CI tests (jest.config.shared.js)"
			}]
		}
	}
	"nodejs_logs": _nodejsArea & {
		name:  "nodejs_logs"
		title: "PostHog Node.js logs ingestion"
		depends_on: ["nodejs_cdp"]
		watch_paths: ["nodejs/src/logs/**", "nodejs/tests/logs/**"]
		jobs: test: shards: 1
		target_scope: {
			tests: ["nodejs/{src,tests}/logs/**/*.test.ts"]
			// Run whole, by its directories: given no file the runner runs every lane's test.
			default_target: "nodejs/src/logs nodejs/tests/logs"
		}
	}
	// The servers: every mode's consumers wired up, and the suites running them end to end.
	"nodejs_servers": _nodejsArea & {
		name:  "nodejs_servers"
		title: "PostHog Node.js servers & ingestion e2e"
		depends_on: ["nodejs_cdp", "nodejs_logs", "nodejs_ingestion", "nodejs_replay"]
		watch_paths: [
			"nodejs/src/servers/**",
			"nodejs/src/{index,server}.ts",
			"nodejs/tests/*.serial.test.ts",
		]
		jobs: test: shards: 1
		target_scope: tests: [
			"nodejs/src/servers/**/*.test.ts",
			"nodejs/tests/*.serial.test.ts",
		]
	}
	// The package as ci-nodejs.yml checks it whole: format, lint and the build (tsc), on any
	// change to it or to an area's dependency, and the Rust ingestion consumer's e2e.
	"nodejs": {
		name:       "nodejs"
		title:      "PostHog Node.js Ingestion & Plugin Server"
		technology: ["typescript", "python", "rust"]
		root:       "nodejs"
		// Its builds compile in the Rust workspace: turbo's prepare builds the
		// replay-anonymizer napi addon (`cargo build --release`), rust_ingestion_e2e the
		// ingestion consumer; CI restores and saves their rust/target cache.
		cargo: workspace: "rust"
		// proto/: ingestion-worker-proto's build script compiles it (rust_ingestion_e2e).
		depends_on: ["nodejs_servers", "proto"]
		workspace_scope: include: _nodejsCone
		// ci-nodejs.yml's rust filter: a change affecting ingestion-consumer
		// (RUST_NODE_E2E_CRATES, by affected-services' determinator) runs every job, as a
		// change to it or to a workspace crate it builds from.
		watch_paths: [
			"rust/ingestion-consumer/**",
			// Its build script compiles proto/.
			"rust/ingestion-worker-proto/**",
			"rust/common/{alloc,continuous_profiling,k8s-awareness,kafka-consumer,lifecycle,liveness}/**",
			// The Rust jobs' build settings the e2e's consumer builds with.
			"showcase/scripts/rust_ci_env.sh",
		]
		// ci-nodejs.yml's format:check and lint (prettier; eslint, then oxlint with the
		// package's .oxlintrc.nodejs.json), on the package's own changed sources: its
		// dependencies' watch paths take in Rust crates and Django files too, which the tools
		// reject from here.
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
		uses: _nodejsServices
	}
}
