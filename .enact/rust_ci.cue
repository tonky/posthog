package replay

import (
	"list"

	"enact.dev/schema"
)

// What marks every Rust crate affected (affected-services' determinator): its every-crate
// rules and its default ones (the workspace manifest and cargo configuration), and Cargo.lock,
// for its graph diff, which marks a crate whose dependencies changed: any lock change here.
// A job running when a given crate is affected watches these, the crate and the workspace
// crates it builds from (`cargo metadata` path dependencies, transitively). The workspace's
// own, which a workflow filtering on rust/** alone (ci-nodejs.yml) sees too:
_rustWorkspaceEveryCrate: [
	"rust/Cargo.toml",
	"rust/Cargo.lock",
	"rust/.cargo/**",
	"rust/.sqlx/**",
	"rust/Dockerfile",
	"rust/Dockerfile.sqlx-migrate",
]
// and the ones outside it, which ci-rust.yml's filter lists, but bin/download-mmdb: geoip's,
// which the suites installing the GeoIP database depend on (personhog_gate's never reads it).
_rustEveryCrate: list.Concat([_rustWorkspaceEveryCrate, [
	"manage.py",
	"posthog/settings/**",
], _djangoMigrations])

// usage-ingestion's integration test binaries whose every test is #[ignore]d: ci-rust.yml's
// ignored step runs them (rust_services:test_ignored), its test job none of their tests.
_rustIgnoredBinaries: ["rust/usage-ingestion/tests/{e2e,load,counters}.rs"]

// The Rust services a live stack runs (live_posthog.sh's live_build_rust: run_e2e_tests.sh
// builds capture and personhog, run_mcp_integration.sh the flags service and personhog) and
// the workspace crates they build from (`cargo metadata` path dependencies, normal and build,
// transitively), with what marks every crate affected: a change there changes the servers
// the specs drive, traced or not.
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
	// ci-rust.yml's "PersonHog e2e gate": personhog-test-harness's own tests with
	// --include-ignored, then its gate scenarios against a spawned personhog stack
	// (run_personhog_gate.sh), on upstream's Postgres, Kafka and etcd. A component of its own
	// for upstream's condition: the job runs when personhog-test-harness is affected, which
	// is (affected-services' determinator) a change to it, to a service it spawns
	// (determinator-rules.toml's package rule) or to a workspace crate they build from, or a
	// change marking every crate affected.
	"personhog_gate": {
		name:        "personhog_gate"
		title:       "PersonHog e2e gate"
		description: "The personhog stack under the test harness's chaos scenarios"
		technology:  "rust"
		// The harness's crate (a component's root is its own: rust/ is rust_services'), built
		// in the Rust workspace's target dir.
		root: "rust/personhog-test-harness"
		cargo: workspace: "rust"
		// proto/: personhog-proto's build script compiles it.
		depends_on: ["test_env", "proto"]
		workspace_scope: include: ["rust", "proto"]
		watch_paths: list.Concat([[
			// The harness, the services it spawns and the workspace crates they build from
			// (`cargo metadata` path dependencies, transitively).
			"rust/personhog-*/**",
			"rust/common/{alloc,assignment-coordination,database,health,ingestion_warnings,k8s-awareness,kafka,keyed-stash,lifecycle,liveness,metrics,sqlx-macros,types}/**",
			"showcase/scripts/run_personhog_gate.sh",
			"showcase/scripts/free_ports.sh",
		], _rustEveryCrate])
		// The harness spawns the stack on a block of ports run_personhog_gate.sh reserves
		// host-wide (free_ports.sh, patches/0019). Upstream: 25 minutes on a 4-core runner.
		jobs: test: {
			resources: {cpus: 4, memory_mb: 8192}
			// run_personhog_gate.sh records the gate with the stack it spawns (enact trace run,
			// rust_footprint.py): on Linux.
			recorder: "own_linux"
			// Its run's size: no coverage build.
			record_resources: resources
			// One test, the whole gate (its scenarios are no files and share one stack build),
			// named by the scenarios' module: its footprint holds what the harness and the
			// services it spawns were built from, and what they read running.
			target_scope: {
				tests: ["rust/personhog-test-harness/src/scenarios/gate.rs"]
				rules: [{match: ["rust/**"], engine: "reach"}]
			}
			tasks: [{
				command: "../../showcase/scripts/run_personhog_gate.sh {targets}"
				timeout: "40m"
			}]
		}
		uses: [
			{protocol: schema.#Protocol.Sql, target: pipeline.services.postgres},
			{protocol: schema.#Protocol.Kafka, target: pipeline.services.kafka},
			{protocol: schema.#Protocol.Grpc, target: pipeline.services.etcd},
		]
	}
	// ci-rust-flags-integration.yml's "Rust /flags Integration Tests": the Rust flags
	// service, personhog's replica and router and Django's API server, then pytest of
	// posthog/api/test/rust_integration/ against them (run_flags_integration.sh). Its paths
	// are upstream's filter.
	"flags_integration": {
		name:        "flags_integration"
		title:       "Rust /flags integration tests"
		description: "Django's flag API and the Rust flags service, evaluated side by side"
		technology: ["rust", "python"]
		// Its tests' directory, not ".": a root-level component's cone audit would check every
		// Django file its include holds, though it runs these tests alone.
		root: "posthog/api/test/rust_integration"
		// Builds in the Rust workspace's target dir, rust_services' and personhog_gate's.
		cargo: workspace: "rust"
		// Not py-root, as rust_services: upstream's filter lists no Python lockfile. proto/:
		// personhog's build scripts compile it. geoip: run_flags_integration.sh installs the
		// GeoIP database the servers read.
		depends_on: ["test_env", "proto", "geoip"]
		workspace_scope: include: list.Concat([_djangoTree, ["rust", "proto", "docker", "infra"]])
		// And the servers it builds with the crates they build from, as the live stacks'.
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
		// Upstream: 30 minutes on a 2-core runner.
		jobs: test: {
			resources: {cpus: 2, memory_mb: 6144}
			// run_flags_integration.sh records each test file with the servers it drives
			// (enact trace run, rust_footprint.py): on Linux.
			recorder: "own_linux"
			// Its run's size: no coverage build.
			record_resources: resources
			tasks: [{
				command: "../../../../showcase/scripts/run_flags_integration.sh {targets}"
				timeout: "45m"
			}]
		}
		// Upstream's Postgres and Redis; the templates' bootstrap (test_databases.sh) migrates
		// ClickHouse and creates Kafka topics too.
		uses: _ingestionServices
	}
}
