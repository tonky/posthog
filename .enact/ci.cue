package replay

import (
	"strings"
	"enact.dev/schema"
)

// This crate owns a separate Cargo workspace: rust/target never contains its native
// binding. Immutable source keys avoid uploading another archive for a JS-only edit.
// Keep restore exact: another architecture, job or native source state is not a fallback.
_hogvmNativeInputs: [
	"enve.lock",
	"enve.cue",
	"rust/Cargo.toml",
	".cargo/config*",
	"rust/.cargo/config*",
	"rust/common/.cargo/config*",
	"rust/common/hogvm/.cargo/config*",
	"rust/common/hogvm/node/.cargo/config*",
	"rust-toolchain*",
	"rust/rust-toolchain*",
	"rust/common/hogvm/Cargo.toml",
	"rust/common/hogvm/build.rs",
	"rust/common/hogvm/src/**",
	"rust/common/hogvm/node/Cargo.toml",
	"rust/common/hogvm/node/Cargo.lock",
	"rust/common/hogvm/node/build.rs",
	"rust/common/hogvm/node/src/**",
	"rust/common/hogvm/node/package.json",
	"rust/common/hogvm/node/turbo.json",
	"turbo.json",
	".enact/*.cue",
	"showcase/scripts/run_nodejs_tests.sh",
	"showcase/scripts/build_hogvm.sh",
	"showcase/scripts/rust_ci_env.sh",
]
_hogvmNativeKey: "hogvm-native-v1-${{ runner.os }}-${{ runner.arch }}-${{ matrix.task_id }}-${{ hashFiles(" + strings.Join([for file in _hogvmNativeInputs {"'\(file)'"}], ", ") + ") }}"

pipeline: schema.#Pipeline & {
	caches: "hogvm-native": {
		name: "Standalone HogVM native target"
		paths: ["rust/common/hogvm/node/target"]
		scope: "task"
		key: [_hogvmNativeKey]
		restore_keys: [_hogvmNativeKey]
		used_by: {
			components: ["nodejs", "nodejs_base", "nodejs_ingestion_core", "nodejs_ingestion", "nodejs_cdp", "nodejs_replay", "nodejs_logs", "nodejs_servers", "e2e"]
			jobs: [pipeline.#jobs.build, pipeline.#jobs.test, pipeline.#jobs.rust_ingestion_e2e]
		}
	}
	toolchain: {
		node: package_manager: "pnpm"
		python: {
			package_manager: "uv"
			install:         "bash showcase/scripts/setup.sh backend"
			// What the install leaves: a run whose stamp is current but finds one missing
			// (a deleted .venv) installs again.
			outputs: [".venv/pyvenv.cfg", ".venv/.replay-provisioned.json"]
		}
	}

	ci: {
		// The Node shards supervise their own services outside enact's outer run log.
		diagnostic_paths: [".enact/state/nodejs/*.services.log"]
		no_cache: {
			labels: ["no-cache", "showcase"]
			branch_prefixes: ["showcase/"]
		}
		concurrency: {
			max_parallel_jobs: 16
		}
		// Upstream's workflows the overlay keeps for the tests that read them (apply-overlay.sh's
		// `keep` entries, each naming its reader): the fork never runs them (its upstream
		// workflows are disabled), so simulate only reports their findings.
		kept_workflows: [
			".github/workflows/cd-sandbox-base-image.yml",
			".github/workflows/ci-backend.yml",
			".github/workflows/ci-python.yml",
			".github/workflows/ci-security.yaml",
			".github/workflows/update-ai-costs.yml",
			".github/workflows/update-sandbox-agent-version.yml",
		]
		// Each host serves its declared size labels under its shared CPU/RAM budget
		// (agentic/KNOWLEDGE.md tonky-ci); available counts hosts, not runner slots.
		workers: {
			"mac1": {
				labels: ["self-hosted", "Linux", "ARM64", "tonky-ci"]
				tier:         "dedicated"
				available:    1
				cost_per_min: 0.010
				pool: {
					cpus:      4
					memory_mb: 8192
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
					}
				}
				timeout_minutes: 90
			}
			"standard": {
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"]
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				pool: {
					cpus:      14
					memory_mb: 28672
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
						"tonky-ci-l": {cpus: 6, memory_mb: 13312}
					}
				}
				timeout_minutes: 90
			}
		}
	}
	workflows: {
		ci: {
			layout:   "staged"
			services: "on_demand"
			stages: [
				// The ARM VM can run these checks while ibp8 serves the test matrix.
				_preflightStage & {runner: "mac1"},
				_testStage,
			]
		}
	}
}
