package replay

import (
	"list"

	"enact.dev/schema"
)

pipeline: components: {
	// mcp_integration's runner (run_mcp_integration.sh): its harness, as live_harness is.
	"mcp_integration_harness": {
		name:       "mcp_integration_harness"
		title:      "MCP integration runner"
		technology: ["python", "typescript"]
		root:       "."
		depends_on: ["live_harness"]
		watch_paths: ["showcase/scripts/run_mcp_integration.sh"]
	}
	// ci-mcp.yml's "Integration Tests": the MCP server's tools against the whole backend,
	// booted prod-like with demo data (run_mcp_integration.sh).
	"mcp_integration": {
		name:        "mcp_integration"
		title:       "MCP integration tests"
		description: "The MCP server's tools driving a live PostHog API over HTTP"
		technology: ["typescript", "python", "rust"]
		// The suite's directory: its targets are the integration test files under it.
		root: "services/mcp/tests"
		// Builds the flags service and personhog in the Rust workspace's target dir, as
		// flags_integration does.
		cargo: workspace: "rust"
		// proto/: personhog's build scripts compile it. frontend: the UI apps' bundles every
		// test loads take in its sources (analysis.derived), the app serves its build's pages
		// where one is present, and a change to its styles or build tools runs every test.
		depends_on: ["mcp", "base", "proto", "frontend", "mcp_integration_harness"]
		workspace_scope: include: list.Concat([_djangoTree, ["services/mcp", "rust", "proto", "docker", "infra", "frontend/src/queries"]])
		watch_paths: list.Concat([[
			"rust/persons_migrations/**",
			"showcase/scripts/live_footprint.py",
			"showcase/scripts/rust_footprint.py",
			"showcase/scripts/node_reads.mjs",
		], _liveFlagsRust])
		// Upstream: 45 minutes on depot-ubuntu-24.04-4.
		jobs: test: {
			worker: "standard"
			// run_mcp_integration.sh records (live_footprint.py).
			recorder: "own"
			resources: {cpus: 4, memory_mb: 12288}
			// The UI apps (vitest's global setup builds them when missing) build in a task of
			// their own, before the tests': generate:ui-apps rewrites the tracked
			// src/resources/ui-apps.generated.ts as committed, and a rewrite while the tests'
			// task runs keeps their footprints out. Restored, they and quill's dist are current.
			needs: _mcpUiAppsNeeds
			tasks: [{
				name:    "Build UI apps"
				command: "../../../showcase/scripts/build_mcp_ui_apps.sh"
			}, {
				name:    "Run Tests"
				command: "../../../showcase/scripts/run_mcp_integration.sh {targets}"
				timeout: "60m"
			}]
			// vitest.integration.config.mts's include. The MCP server's code, the frontend's
			// (frontend/src and the product frontends) and the Django app's run the tests whose
			// footprints hold them (live_footprint.py: what vitest loaded, the UI apps' bundles'
			// sources by analysis.derived, the frontend build's sources where the app served it,
			// and the Python the app restarted for each test file read) and those not traced;
			// anything else (the frontend's styles and build tools among it) runs every test.
			target_scope: {
				fallback: "all"
				tests: ["services/mcp/tests/**/*.integration.test.ts"]
				rules: [{
					match: [
						"services/mcp/src/**/*.{ts,tsx,js,mjs}",
						"services/mcp/tests/**/*.ts",
						"products/*/mcp/**/*.{ts,tsx}",
						"frontend/src/**/*.{ts,tsx,js,jsx,mjs}",
						"products/*/frontend/**/*.{ts,tsx,js,jsx,mjs}",
					]
					engine:      "typescript"
					granularity: "file"
				}, {
					match: ["posthog/**/*.py", "ee/**/*.py", "common/**/*.py", "products/**/*.py"]
					engine:      "python"
					granularity: "file"
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
}
