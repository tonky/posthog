package replay

import (
	"list"
	"strings"
	"enact.dev/schema"
)

let J = pipeline.#jobs

_preflightStage: {
	name: "preflight"
	select: list.Concat([
		[
			J.fmt, J.migrate, J.schema_check,
			{component: "agent_proxy", job: J.typecheck},
			{component: "oauth_proxy", job: J.typecheck},
			{component: "integration_service", job: J.typecheck},
		],
		// Keep heavy Rust `cargo clippy` lints (`rust_services:lint`, `cli:lint`) in the matrix
		// stage so `Stage: Preflight` stays lightweight and avoids pulling Rust caches.
		[for name, c in pipeline.components if name != "rust_services" && name != "cli" && (c.lint != _|_ || c.jobs.lint != _|_) {
			component: name, job: J.lint
		}],
	])
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
		{component: "dagster", job: J.typecheck},
		{component: "rust_services", job: J.lint},
		{component: "cli", job: J.lint},
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
_hogvmNativeKey: "hogvm-native-v1-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles(" + strings.Join([for file in _hogvmNativeInputs {"'\(file)'"}], ", ") + ") }}"

_replayAnonymizerInputs: [
	"enve.lock", "enve.cue", "rust/Cargo.toml", "rust/Cargo.lock", ".cargo/config*", "rust/.cargo/config*",
	"rust-toolchain*", "rust/rust-toolchain*", "rust/replay-anonymizer/Cargo.toml", "rust/replay-anonymizer/src/**",
	"rust/replay-anonymizer-node/Cargo.toml", "rust/replay-anonymizer-node/src/**",
	"rust/replay-anonymizer-node/package.json", "rust/replay-anonymizer-node/tsconfig.json",
	"rust/replay-anonymizer-node/turbo.json", "turbo.json", ".enact/*.cue", "showcase/scripts/build_e2e.sh",
	"showcase/scripts/run_nodejs_tests.sh", "showcase/scripts/rust_ci_env.sh",
]
_replayAnonymizerKey: "replay-anonymizer-v1-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles(" + strings.Join([for file in _replayAnonymizerInputs {"'\(file)'"}], ", ") + ") }}"

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
			scope:        "shared"
			key:          [_hogvmNativeKey]
			restore_keys: [_hogvmNativeKey]
			used_by: {
				components: list.Concat([_nodejsSuites, ["e2e"]])
				jobs:       [J.build, J.test, J.rust_ingestion_e2e]
			}
		}
		"replay-anonymizer-native": {
			name:         "Replay anonymizer native release target"
			paths:        ["rust/target/release"]
			scope:        "shared"
			key:          [_replayAnonymizerKey]
			restore_keys: [_replayAnonymizerKey]
			used_by: {
				components: list.Concat([_nodejsSuites, ["e2e"]])
				jobs:       [J.build, J.test, J.rust_ingestion_e2e]
			}
		}
		"live-migrations": {
			name: "Live Postgres and ClickHouse migration snapshots"
			save: {
				when:    "validated_failure"
				command: "python3 showcase/scripts/live_migrate_cache.py verify \"$HOME/.cache/enact/snapshots\""
			}
			paths:   ["~/.cache/enact/snapshots/live-v1", "~/.cache/enact/snapshots/ch-v1"]
			version: "1"
			scope:   "shared"
			used_by: {
				components: ["e2e", "mcp_integration"]
				jobs:       [J.test]
			}
		}
		"backend-templates": {
			name:             "Backend database templates"
			arch_independent: true
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
		soft_placement:   {fallback_seconds: 15}
		history:          {workflow: ".github/workflows/ci.yml"}
		diagnostic_paths: [".enact/state/nodejs/*.services.log"]
		rerun: {
			labels:          ["rerun", "showcase"]
			branch_prefixes: ["showcase/"]
		}
		scheduler: max_matrix_size: 128
		kept_workflows: [
			".github/workflows/cd-sandbox-base-image.yml", ".github/workflows/ci-backend.yml",
			".github/workflows/ci-python.yml", ".github/workflows/ci-security.yaml",
			".github/workflows/update-ai-costs.yml", ".github/workflows/update-sandbox-agent-version.yml",
		]
		remote_cache: {
			secrets: {bucket: "R2_BUCKET", access_key_id: "R2_ACCESS_KEY_ID", secret_access_key: "R2_SECRET_ACCESS_KEY"}
			public_url: "https://cache.tonky.dev"
			public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
			repo:       "tonky/posthog"
			branch:     "perf/ci-showcase"
		}
		allow_broad: branch_prefixes: ["mirror-broad/"]
		budget: {enforce: true, untraced_tests: 10, wall_minutes: 30}
		workers: {
			github: {
				// Standard public capacity; X64 + ARM64 public images share the 20-VM quota_group.
				preset: "github-public", labels: ["ubuntu-24.04"], quota_group: "github-public"
				tier: "on_demand", available: 20, cost_per_min: 0
				// Calibrated from measured ~80s cold preparation on ubuntu-24.04.
				setup_overhead_sec: 80
				throughput:         0.75
				timeout_minutes:    120
			}
			github_arm: {
				preset: "github-public", labels: ["ubuntu-24.04-arm"], arch: "aarch64", quota_group: "github-public"
				tier: "on_demand", available: 20, cost_per_min: 0
				setup_overhead_sec: 80
				throughput:         0.75
				timeout_minutes:    120
			}
			"mac1": {
				labels:          ["self-hosted", "Linux", "ARM64", "tonky-ci"]
				host_id:         "mac1"
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				throughput:      1.35
				timeout_minutes: 120
				pool: {
					cpus:      16
					memory_mb: 36864
					quantization: {
						label_prefix:       "tonky-ci"
						cpu_step:           1
						memory_step_mb:     1024
						runtime_reserve_mb: 2048
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 6, memory_mb: 13312}
						control: {cpus: 2, memory_mb: 6144}
					}
				}
			}
			"standard": {
				labels:          ["self-hosted", "Linux", "X64", "tonky-ci"]
				host_id:         "ibp8"
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				timeout_minutes: 120
				pool: {
					cpus:      14
					memory_mb: 28672
					quantization: {
						label_prefix:       "tonky-ci"
						cpu_step:           1
						memory_step_mb:     1024
						runtime_reserve_mb: 2048
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 6, memory_mb: 13312}
						control: {cpus: 2, memory_mb: 6144}
					}
				}
			}
			l7: {
				// A second X64 host (16t, ~13 GiB free), up to 8c/8G allocations when idle.
				// A gate lane holding l7 drains its dispatcher to zero.
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"], host_id: "l7", tier: "dedicated", available: 1, cost_per_min: 0.006, throughput: 0.95, timeout_minutes: 120
				pool: {
					cpus: 16, memory_mb: 13312
					quantization: {
						label_prefix:       "tonky-ci"
						cpu_step:           1
						memory_step_mb:     1024
						runtime_reserve_mb: 2048
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 8, memory_mb: 8192}
						control: {cpus: 2, memory_mb: 6144}
					}
				}
			}
		}
	}

	workflows: {
		ci: {
			layout:      "staged"
			services:    "on_demand"
			concurrency: {scope: "branch", cancel_in_progress: true}
			stages:      [_preflightStage, _testStage]
		}
		local: {layout: "staged", services: "on_demand", stages: [_preflightStage, _testStage]}
	}
}
