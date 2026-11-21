package replay

import (
	"list"
	"enact.dev/schema"
)

// jest.config.shared.js names frontend/jest.quarantine.ts and .github/scripts/jest-retries.cjs.
_nodejsCone: list.Concat([_djangoTree, ["nodejs", "rust", "proto", "frontend/public/services", "frontend/jest.quarantine.ts", ".github/scripts/jest-retries.cjs", "docker", "infra", "tools/deploy-requirements"]])

_nodejsServices: [
	{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres},
	{protocol: schema.#Protocol.Http, target: pipeline.services.clickhouse},
]

_nodejsSuites: [
	"nodejs", "nodejs_base", "nodejs_ingestion_core", "nodejs_ingestion",
	"nodejs_replay", "nodejs_cdp", "nodejs_logs", "nodejs_servers",
]

_nodejsArea: {
	technology: ["typescript", "python"]
	root:       "."
	shards:      int | *1
	recorder:         "own_linux"
	recorded_by:      ["enact-node"]
	resources:        {cpus: 4, memory_mb: 6144}
	record_resources: resources
	test: {
		command: "showcase/scripts/run_nodejs_tests.sh {targets}"
		timeout: "90m"
	}
	uses: _nodejsServices
}

pipeline: components: {
	"nodejs_env": {
		name:            "nodejs_env"
		title:           "PostHog Node.js suites' environment"
		technology:      "shell"
		root:            "."
		depends_on:      ["js-root", "test_env", "test_quarantine", "build_once", "nodejs_harness"]
		workspace_scope: include: _nodejsCone
		watch_paths: list.Concat([[
			"common/replay-headless/**",
			"common/replay-shared/src/**",
			"common/replay-shared/package.json",
			"common/plugin_transpiler/**",
			"rust/replay-anonymizer/**",
			"rust/replay-anonymizer-node/**",
			"rust/common/hogvm/**",
			"common/hogvm/typescript/src/**",
			"common/hogvm/typescript/{package.json,tsconfig.json,tsconfig.build.json}",
			"rust/common/ingestion_warnings/*.json",
			"posthog/clickhouse/**",
			"posthog/plugins/**",
			"posthog/cdp/filter_globals.json",
			"infra/maildev/**",
		], _rustWorkspaceEveryCrate, _djangoMigrations])
	}
	"nodejs_base": _nodejsArea & {
		name:       "nodejs_base"
		title:      "PostHog Node.js shared core (common, helpers, configs)"
		depends_on: ["nodejs_env"]
		watch_paths: [
			"nodejs/*",
			"nodejs/{assets,bin,sql}/**",
			"nodejs/src/*.yaml",
			"nodejs/src/{capabilities,lifecycle,plugin-scaffold,types}.ts",
			"nodejs/src/common/**",
			"nodejs/src/ai-observability/config.ts",
			"nodejs/src/cdp/{config,types}.ts",
			"nodejs/src/cdp/outputs/producers.ts",
			"nodejs/src/cdp/schema/{cyclotron,hogflow,pushNotification}.ts",
			"nodejs/src/cdp/services/hogflows/transactional-email.ts",
			"nodejs/src/cdp/services/managers/{integration-manager.service,integration-source,postgres-integration-source}.ts",
			"nodejs/src/cdp/services/messaging/{attachment-store,in-flight-registry,message-estimate}.ts",
			"nodejs/src/cdp/utils/{encryption-utils,hog-error-classification,integration-reference,jwt-utils,rebuildable-inputs}.ts",
			"nodejs/src/ingestion/common/outputs/producers.ts",
			"nodejs/src/logs/{config,internal-logs,internal-logs-producer}.ts",
			"nodejs/src/logs/outputs/producers.ts",
			"nodejs/src/servers/base-server.ts",
			"nodejs/tests/{config,utils}.test.ts",
			"nodejs/tests/{assets,fixtures,utils}/**",
			"nodejs/tests/helpers/{clickhouse,compression,database-guard,database-guard.test,event-headers,expectations,fake-ses,hog-invocation-results,kafka-message,kafka,metrics,mock-ingestion-outputs,person,pin-date,pipeline-event,plugin-event,promises,quota-limits,raw-event,recording-ingestion-outputs,redis,service-process,snapshots,snapshots.test,sql,team,tls,truth}.ts",
			"nodejs/tests/helpers/mocks/{consumer.mock,date.mock,producer.mock,producer.spy,request.mock}.ts",
		]
		target_scope: {
			tests: [
				"nodejs/src/common/**/*.test.ts",
				"nodejs/tests/{config,utils}.test.ts",
				"nodejs/tests/{helpers,utils}/**/*.test.ts",
			]
			handoff: [
				{to: "nodejs_replay", tests: ["nodejs/src/common/kafka/consumer/consumer-v2.test.ts", "nodejs/src/common/utils/request-http2.test.ts"]},
				{to: "nodejs_servers", tests: ["nodejs/src/common/api/router.test.ts"]},
			]
			not_run: [{
				tests:  ["nodejs/src/common/personhog/personhog-postgres-parity.serial.test.ts"]
				reason: "ci-nodejs.yml's postgres-parity step (continue-on-error, on an isolated persons database) isn't modeled"
			}]
		}
	}
	"nodejs_ingestion_core": _nodejsArea & {
		name:       "nodejs_ingestion_core"
		title:      "PostHog Node.js ingestion framework & common steps"
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
		target_scope: {
			tests: ["nodejs/src/ingestion/{framework,common}/**/*.test.ts", "nodejs/tests/ingestion/{framework,common}/**/*.test.ts"]
			handoff: [
				{to: "nodejs_ingestion", tests: ["nodejs/tests/ingestion/framework/batching-pipeline.integration.test.ts"]},
				{to: "nodejs_servers", tests: ["nodejs/src/ingestion/common/steps/event-processing/hog-transform-event-step.test.ts"]},
			]
		}
	}
	"nodejs_ingestion": _nodejsArea & {
		name:       "nodejs_ingestion"
		title:      "PostHog Node.js event ingestion pipelines"
		depends_on: ["nodejs_ingestion_core"]
		watch_paths: [
			"nodejs/src/ingestion/*.ts",
			"nodejs/src/ingestion/{__snapshots__,api,doctor}/**",
			"nodejs/src/ingestion/pipelines/{ai,analytics,clientwarnings,errortracking,heatmaps,metrics}/**",
			"nodejs/tests/ingestion/*.ts",
			"nodejs/tests/ingestion/pipelines/{clientwarnings,heatmaps}/**",
			"nodejs/tests/service-e2e/personhog-shadow-parity.serial.test.ts",
			"nodejs/src/logs/services/unknown-token-recorder.ts",
			"nodejs/tests/helpers/ingestion-outputs.ts",
			".github/workflows/update-ai-costs.yml",
		]
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
			not_run: [
				{tests: ["nodejs/tests/ingestion/postgres-parity.test.ts"], reason: "ci-nodejs.yml's postgres-parity step (continue-on-error, on an isolated persons database) isn't modeled"},
				{tests: ["nodejs/tests/service-e2e/personhog-shadow-parity.serial.test.ts"], reason: "no upstream workflow runs it (the lanes ignore service-e2e)"},
			]
		}
	}
	"nodejs_replay": _nodejsArea & {
		name:       "nodejs_replay"
		title:      "PostHog Node.js session replay"
		cargo: workspace: "rust"
		depends_on: ["nodejs_ingestion_core"]
		watch_paths: [
			"nodejs/src/session-replay/**",
			"nodejs/src/ingestion/pipelines/sessionreplay/**",
			"nodejs/tests/session-replay/**",
			"nodejs/tests/ingestion/pipelines/sessionreplay/**",
			"nodejs/tests/helpers/ml-mirror-staged-batch.ts",
		]
		shards: 2
		target_scope: {
			tests: [
				"nodejs/src/session-replay/**/*.test.ts",
				"nodejs/src/ingestion/pipelines/sessionreplay/**/*.test.ts",
				"nodejs/tests/session-replay/**/*.test.ts",
				"nodejs/tests/ingestion/pipelines/sessionreplay/**/*.test.ts",
			]
			handoff: [{to: "nodejs_servers", tests: ["nodejs/src/ingestion/pipelines/sessionreplay/ai-research/image-fetch-v4/v4-lane.test.ts"]}]
			not_run: [{
				tests:  ["nodejs/src/ingestion/pipelines/sessionreplay/ml-mirror-image-scrub-sidecar/**"]
				reason: "a package of its own the plugin server's jest leaves out (modulePathIgnorePatterns), and no upstream workflow runs its jest"
			}]
		}
	}
	"nodejs_cdp": _nodejsArea & {
		name:       "nodejs_cdp"
		title:      "PostHog Node.js CDP & AI observability"
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
		shards: 2
		target_scope: {
			tests:   ["nodejs/src/{cdp,ai-observability}/**/*.test.ts"]
			handoff: [{to: "nodejs_servers", tests: [
				"nodejs/src/cdp/cdp-api.serial.test.ts",
				"nodejs/src/cdp/consumers/cdp-cyclotron-worker-email.consumer.serial.test.ts",
				"nodejs/src/cdp/hog-transformations/hog-transformer.service.test.ts",
				"nodejs/src/cdp/services/messaging/email.service.test.ts",
			]}]
			not_run: [
				{tests: ["nodejs/src/cdp/dev/**"], reason: "dev-only scripts and benchmarks, never CI tests (jest.config.shared.js)"},
				{
					tests: [
						"nodejs/src/cdp/intake/intake-batch.serial.test.ts",
						"nodejs/src/cdp/services/cyclotron-v2/cyclotron-v2.test.ts",
						"nodejs/src/cdp/services/invocation-results.service.test.ts",
						"nodejs/src/cdp/services/job-queue/job-queue-postgres-v2.serial.test.ts",
					]
					reason: "O1 pin cb94c35517cf: Cyclotron Postgres v2 / invocation-results failure at pin; revisit on next pin bump (usecases/posthog/LEARNINGS.md)"
				},
			]
		}
	}
	"nodejs_logs": _nodejsArea & {
		name:        "nodejs_logs"
		title:       "PostHog Node.js logs ingestion"
		depends_on:  ["nodejs_cdp", "nodejs_ingestion_core"]
		watch_paths: ["nodejs/src/logs/**", "nodejs/tests/logs/**"]
		target_scope: {
			tests:          ["nodejs/{src,tests}/logs/**/*.test.ts"]
			default_target: "nodejs/src/logs nodejs/tests/logs"
		}
	}
	"nodejs_servers": _nodejsArea & {
		name:        "nodejs_servers"
		title:       "PostHog Node.js servers & ingestion e2e"
		cargo: workspace: "rust"
		depends_on:  ["nodejs_cdp", "nodejs_logs", "nodejs_ingestion", "nodejs_replay"]
		watch_paths: [
			"nodejs/src/servers/**",
			"nodejs/src/{index,server}.ts",
			"nodejs/src/messaging/**",
			"nodejs/src/schema-check/**",
			"nodejs/tests/*.serial.test.ts",
			"nodejs/tests/scenarios/**",
		]
		target_scope: {
			tests: [
				"nodejs/src/servers/**/*.test.ts",
				"nodejs/src/messaging/**/*.test.ts",
				"nodejs/src/schema-check/**/*.test.ts",
				"nodejs/tests/*.serial.test.ts",
				"nodejs/tests/scenarios/**/*.test.ts",
			]
			not_run: [{
				tests: [
					"nodejs/tests/scenarios/cloud/host-pooler.test.ts",
					"nodejs/tests/scenarios/cloud/host-prepare.test.ts",
					"nodejs/tests/scenarios/environment/environment.test.ts",
				]
				reason: "O1 pin cb94c35517cf: cloud/environment scenario harness assumes fixed Postgres/Docker setup; revisit on next pin bump (usecases/posthog/LEARNINGS.md)"
			}]
		}
	}
	"nodejs": {
		name:            "nodejs"
		title:           "PostHog Node.js Ingestion & Plugin Server"
		technology:      ["typescript", "python", "rust"]
		root:            "nodejs"
		cargo: workspace: "rust"
		depends_on:      ["nodejs_servers", "proto"]
		workspace_scope: include: list.Concat([_nodejsCone, [".github/workflows/update-ai-costs.yml"]])
		watch_paths: [
			"rust/ingestion-consumer/**",
			"rust/ingestion-worker-proto/**",
			"rust/common/{alloc,continuous_profiling,k8s-awareness,kafka-consumer,lifecycle,liveness}/**",
			"showcase/scripts/rust_ci_env.sh",
		]
		jobs: {
			fmt: {
				services: false
				tasks: [{command: "pnpm exec prettier --check --ignore-unknown --no-error-on-unmatched-pattern {relative_changed_files}", filter: include: ["nodejs/**"]}]
			}
			lint: {
				services: false
				tasks: [{command: "pnpm exec eslint {relative_changed_files} && pnpm exec oxlint -c .oxlintrc.nodejs.json --no-error-on-unmatched-pattern {relative_changed_files}", filter: include: ["nodejs/**/*.{ts,tsx,js,mjs,cjs}"]}]
			}
			rust_ingestion_e2e: {
				shards:           1
				target_scope:     tests: ["nodejs/tests/service-e2e/rust-ingestion-consumer.serial.test.ts"]
				resources:        {cpus: 4, memory_mb: 8192}
				recorder:         "own_linux"
				record_resources: resources
				tasks: [{command: "../showcase/scripts/run_nodejs_tests.sh --rust-ingestion-e2e {targets}", timeout: "45m"}]
			}
			build: {
				services:  false
				resources: {cpus: 4, memory_mb: 6144}
				tasks: [{
					name:    "Build Package"
					dir:     "."
					lock:    "nodejs-build"
					command: "showcase/scripts/build_hogvm.sh && showcase/scripts/exclusive.sh nodejs-build bin/turbo --filter=@posthog/nodejs prepare && pnpm --filter=@posthog/nodejs build"
					timeout: "25m"
				}]
			}
		}
		uses:  _nodejsServices
	}
}
