package replay

import (
	"list"
	"enact.dev/schema"
)

_rustWorkspaceEveryCrate: [
	"rust/Cargo.toml", "rust/Cargo.lock", "rust/.cargo/**", "rust/.sqlx/**",
	"rust/Dockerfile", "rust/Dockerfile.sqlx-migrate",
]
_rustEveryCrate:    list.Concat([_rustWorkspaceEveryCrate, ["manage.py", "posthog/settings/**"], _djangoMigrations])
_rustIgnoredBinaries: ["rust/usage-ingestion/tests/{e2e,load,counters}.rs"]

_livePersonhogRust: [
	"rust/personhog-{common,coordination,proto,replica,router}/**",
	"rust/common/{alloc,assignment-coordination,database,k8s-awareness,keyed-stash,lifecycle,liveness,metrics}/**",
]
_liveCaptureRust: list.Concat([_livePersonhogRust, _rustWorkspaceEveryCrate, [
	"rust/capture/**",
	"rust/common/{compression,continuous_profiling,health,ingestion_warnings,kafka,limiters,redis,types}/**",
]])
_liveFlagsRust: list.Concat([_livePersonhogRust, _rustWorkspaceEveryCrate, [
	"rust/feature-flags/**",
	"rust/usage-ingestion-proto/**",
	"rust/common/{cache,compression,continuous_profiling,cookieless,geoip,hypercache,limiters,redis,s3,types}/**",
]])

pipeline: components: {
	"personhog_gate": {
		name:            "personhog_gate"
		title:           "PersonHog e2e gate"
		description:     "The personhog stack under the test harness's chaos scenarios"
		technology:      "rust"
		root:            "rust/personhog-test-harness"
		cargo: workspace: "rust"
		depends_on:      ["test_env", "proto"]
		workspace_scope: include: ["rust", "proto"]
		watch_paths: list.Concat([[
			"rust/personhog-*/**",
			"rust/common/{alloc,assignment-coordination,database,health,ingestion_warnings,k8s-awareness,kafka,keyed-stash,lifecycle,liveness,metrics,sqlx-macros,types}/**",
			"showcase/scripts/run_personhog_gate.sh",
			"showcase/scripts/free_ports.sh",
		], _rustEveryCrate])
		jobs: test: {
			resources:        {cpus: 4, memory_mb: 8192}
			recorder:         "own_linux"
			record_resources: resources
			target_scope: {
				tests: ["rust/personhog-test-harness/src/scenarios/gate.rs"]
				rules: [{match: ["rust/**"], engine: "reach"}]
			}
			tasks: [{command: "../../showcase/scripts/run_personhog_gate.sh {targets}", timeout: "40m"}]
		}
		uses: [
			{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres},
			{protocol: schema.#Protocol.Kafka, target: pipeline.services.kafka},
			{protocol: schema.#Protocol.Grpc, target: pipeline.services.etcd},
		]
	}
	"flags_integration": {
		name:            "flags_integration"
		title:           "Rust /flags integration tests"
		description:     "Django's flag API and the Rust flags service, evaluated side by side"
		technology:      ["rust", "python"]
		root:            "posthog/api/test/rust_integration"
		cargo: workspace: "rust"
		depends_on:      ["test_env", "proto", "geoip"]
		workspace_scope: include: list.Concat([_djangoTree, ["rust", "proto", "docker", "infra"]])
		watch_paths: list.Concat([[
			"posthog/api/feature_flag.py",
			"posthog/api/cohort.py",
			"posthog/models/feature_flag/**",
			"posthog/models/cohort/**",
			"posthog/models/group_type_mapping.py",
			"showcase/scripts/run_flags_integration.sh",
			"showcase/scripts/rust_ci_env.sh",
			"showcase/scripts/rust_footprint.py",
		], _liveFlagsRust])
		jobs: test: {
			resources:        {cpus: 2, memory_mb: 6144}
			recorder:         "own_linux"
			record_resources: resources
			tasks: [{command: "../../../../showcase/scripts/run_flags_integration.sh {targets}", timeout: "45m"}]
		}
		uses: _ingestionServices
	}
}
