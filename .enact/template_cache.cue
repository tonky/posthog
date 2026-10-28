package replay

// Every job whose runner clones or migrates the shared Postgres templates through
// showcase/scripts/test_databases.sh (`with_templates` / `prepare_worker_databases`):
//   - base:test, products:test, dagster:test (run_sharded_pytest.sh)
//   - base:audit (repo_invariants.sh)
//   - the nodejs_* areas' test, nodejs:rust_ingestion_e2e (run_nodejs_tests.sh)
//   - rust_services:test (run_rust_tests.sh; test_ignored needs no Postgres template)
//   - flags_integration:test (run_flags_integration.sh)
//   - e2e:test, mcp_integration:test (live_posthog.sh)
pipeline: caches: "backend-templates": {
	name: "Backend database templates"
	save: {
		when:    "validated_failure"
		command: "python3 showcase/scripts/template_publications.py \"$HOME/.cache/enact/snapshots/v3\""
	}
	paths: ["~/.cache/enact/snapshots/v3"]
	// The helper validates content and runtime; transport stays stable across setup.
	// 4: each dump lists its migrations (migrations.json), so a miss can top one up.
	version: "4"
	scope:   "shared"
	used_by: {
		components: [
			"base",
			"products",
			"dagster",
			"nodejs",
			"nodejs_base",
			"nodejs_ingestion_core",
			"nodejs_ingestion",
			"nodejs_replay",
			"nodejs_cdp",
			"nodejs_logs",
			"nodejs_servers",
			"rust_services",
			"flags_integration",
			"e2e",
			"mcp_integration",
		]
		jobs: [
			pipeline.#jobs.test,
			pipeline.#jobs.audit,
			pipeline.#jobs.rust_ingestion_e2e,
		]
	}
}
