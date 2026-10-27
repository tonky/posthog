package replay

// ci-dagster.yml's "Dagster tests": posthog/dags and every product's dags/ in one pytest
// from the root, with two reruns (product_pytest.py's `dags` run), against the backend's
// services, in three shards.
pipeline: components: "dagster": {
	name:        "dagster"
	title:       "Dagster jobs"
	description: "Dagster assets and jobs of core and the products"
	technology:  "python"
	root:        "."
	// The DAGs import core and the products: a change to them runs the dags tests importing
	// what changed (the python rule), as ci-dagster.yml's full filter lists the modules the
	// DAGs import.
	depends_on: ["base", "products", "py-root", "test_env"]
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
	watch_paths: [
		"posthog/dags/**",
		"products/*/dags/**",
		"dagster_cloud.yaml",
		".dagster_home/**",
	]
	// Upstream's three shards; per shard as base's (a shard waits on its services).
	shards: 3
	resources: {
		cpus:      0.75
		memory_mb: 2800
	}
	scoping: {
		domain_roots: ["posthog", "products"]
		service_markers: ["django_db", "BaseTest", "ClickhouseTestMixin", "posthog.test"]
	}
	target_scope: {
		fallback: "none"
		rules: [{
			match: [
				"posthog/**/*.{py,ambr}",
				"ee/**/*.py",
				"common/**/*.py",
				"packages/personhog-proto/**/*.py",
				"products/**/*.{py,ambr}",
			]
			engine:      "python"
			granularity: "file"
		}]
		tests: [for root in ["posthog/dags", "products/*/dags"] for f in _pytestFiles {"\(root)/**/\(f)"}]
	}
	// run_sharded_pytest.sh records (pytest_footprint.py).
	recorder: "own"
	// The plugin in the shard's own pytest: a recording shard is a test shard.
	record_resources: resources
	// A cold shard bootstraps the shared template databases first, as base's (its timeout).
	test: {
		// Through the env's bash, as base's: SIP strips the shebang's /usr/bin/env children of
		// DYLD_*, and xgboost's wheel loads the env's libomp.
		command: "bash showcase/scripts/run_sharded_pytest.sh {targets}"
		timeout: "90m"
		error_exit_codes: _pytestErrors
	}
	uses: _backendServices
}
