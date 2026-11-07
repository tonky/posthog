package replay

import (
	"list"
	"strings"
	"enact.dev/schema"
)

let J = pipeline.#jobs

_preflightStage: {
	name: "preflight"
	select: [
		J.lint, J.fmt, J.migrate, J.schema_check,
		{component: "agent_proxy", job: J.typecheck},
		{component: "oauth_proxy", job: J.typecheck},
		{component: "integration_service", job: J.typecheck},
		{component: "dagster", job: J.typecheck},
	]
	fail_fast: true
	services:  "disabled"
}

_testStage: {
	name:   "tests"
	matrix: true
	select: [
		J.test, J.test_typescript, J.test_hono, J.test_ignored, J.rust_ingestion_e2e, J.webkit,
		{component: "products", job: J.typecheck},
		{component: "frontend", job: J.typecheck},
		{component: "mcp", job: J.typecheck},
		{component: "desktop", job: J.typecheck},
		J.audit, J.build, J.jscpd,
	]
	fail_fast: false
	services:  "on_demand"
}

_hogvmNativeInputs: [
	"enve.lock", "enve.cue", "rust/Cargo.toml", ".cargo/config*", "rust/.cargo/config*",
	"rust/common/.cargo/config*", "rust/common/hogvm/.cargo/config*", "rust/common/hogvm/node/.cargo/config*",
	"rust-toolchain*", "rust/rust-toolchain*", "rust/common/hogvm/Cargo.toml", "rust/common/hogvm/build.rs",
	"rust/common/hogvm/src/**", "rust/common/hogvm/node/Cargo.toml", "rust/common/hogvm/node/Cargo.lock",
	"rust/common/hogvm/node/build.rs", "rust/common/hogvm/node/src/**", "rust/common/hogvm/node/package.json",
	"rust/common/hogvm/node/turbo.json", "turbo.json", ".enact/*.cue", "showcase/scripts/run_nodejs_tests.sh",
	"showcase/scripts/build_hogvm.sh", "showcase/scripts/rust_ci_env.sh",
]
_hogvmNativeKey: "hogvm-native-v1-${{ runner.os }}-${{ runner.arch }}-${{ matrix.task_id }}-${{ hashFiles(" + strings.Join([for file in _hogvmNativeInputs {"'\(file)'"}], ", ") + ") }}"

pipeline: schema.#Pipeline & {
	services: {
		postgres:         {name: "postgres", enact: kind: schema.#ServiceKind.Postgres}
		redis:            {name: "redis", enact: kind: schema.#ServiceKind.Redis}
		clickhouse:       {name: "clickhouse", enact: kind: schema.#ServiceKind.ClickHouse}
		kafka:            {name: "kafka", enact: kind: schema.#ServiceKind.Kafka}
		seaweedfs:        {name: "seaweedfs", enact: {kind: schema.#ServiceKind.ObjectStorage, buckets: ["posthog", "ducklake-dev", "ai-blobs"]}}
		"seaweedfs-open": {name: "seaweedfs-open", enact: buckets: ["posthog"]}
		temporal:         {name: "temporal", enact: kind: schema.#ServiceKind.Temporal}
		etcd:             name: "etcd"
		"valkey-cluster": name: "valkey-cluster"
		azurite:          name: "azurite"
	}

	caches: {
		"hogvm-native": {
			name:         "Standalone HogVM native target"
			paths:        ["rust/common/hogvm/node/target"]
			scope:        "task"
			key:          [_hogvmNativeKey]
			restore_keys: [_hogvmNativeKey]
			used_by: {
				components: list.Concat([_nodejsSuites, ["e2e"]])
				jobs:       [J.build, J.test, J.rust_ingestion_e2e]
			}
		}
		"backend-templates": {
			name: "Backend database templates"
			save: {
				when:    "validated_failure"
				command: "python3 showcase/scripts/template_publications.py \"$HOME/.cache/enact/snapshots/v3\""
			}
			paths:   ["~/.cache/enact/snapshots/v3"]
			version: "4"
			scope:   "shared"
			used_by: {
				components: list.Concat([
					["base", "products", "dagster"],
					_nodejsSuites,
					["rust_services", "flags_integration", "e2e", "mcp_integration"],
				])
				jobs: [J.test, J.audit, J.rust_ingestion_e2e]
			}
		}
	}

	toolchain: {
		node: package_manager: "pnpm"
		python: {
			package_manager: "uv"
			install:         "bash showcase/scripts/setup.sh backend"
			outputs:         [".venv/pyvenv.cfg", ".venv/.replay-provisioned.json"]
		}
	}

	ci: {
		diagnostic_paths: [".enact/state/nodejs/*.services.log"]
		rerun: {
			labels:          ["rerun", "showcase"]
			branch_prefixes: ["showcase/"]
		}
		concurrency: max_parallel_jobs: 16
		kept_workflows: [
			".github/workflows/cd-sandbox-base-image.yml", ".github/workflows/ci-backend.yml",
			".github/workflows/ci-python.yml", ".github/workflows/ci-security.yaml",
			".github/workflows/update-ai-costs.yml", ".github/workflows/update-sandbox-agent-version.yml",
		]
		remote_cache: {
			secrets: {bucket: "R2_BUCKET", access_key_id: "R2_ACCESS_KEY_ID", secret_access_key: "R2_SECRET_ACCESS_KEY"}
			public_url: "https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev"
			public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
			repo:       "tonky/posthog"
			branch:     "perf/ci-showcase"
		}
		budget: {enforce: true, untraced_tests: 10, wall_minutes: 30}
		workers: {
			"mac1": {
				labels:          ["self-hosted", "Linux", "ARM64", "tonky-ci", "mac1"]
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				timeout_minutes: 90
				pool: {
					cpus:      16
					memory_mb: 36864
					floor: {cpus: 4, memory_mb: 8192} // mac1 under its lane clamp (KNOWLEDGE `tonky-ci` load clamp)
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
						"tonky-ci-l": {cpus: 6, memory_mb: 13312}
					}
				}
			}
			"standard": {
				labels:          ["self-hosted", "Linux", "X64", "tonky-ci", "ibp8"]
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				timeout_minutes: 90
				pool: {
					cpus:      14
					memory_mb: 28672
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
						"tonky-ci-l": {cpus: 6, memory_mb: 13312}
					}
				}
			}
			l7: {
				// A second X64 host (8c/14G): s and m only; a gate lane holding l7 drains it to zero.
				// A size costs the rate times its share of the largest size: 0.006 prices its m as
				// the 13 GB pools price theirs.
				labels: ["self-hosted", "Linux", "X64", "tonky-ci", "l7"], tier: "dedicated", available: 1, cost_per_min: 0.006, timeout_minutes: 90
				pool: {
					cpus: 8, memory_mb: 12288
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
					}
				}
			}
		}
	}

	workflows: {
		ci:    {layout: "staged", services: "on_demand", stages: [_preflightStage & {runner: "mac1"}, _testStage]}
		local: {layout: "staged", services: "on_demand", stages: [_preflightStage, _testStage]}
	}
}
