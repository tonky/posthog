package replay

import "enact.dev/schema"

pipeline: schema.#Pipeline & {
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
		// The fork's jobs run on the user's tonky-ci fleet, one fresh container per job (enact's
		// .enact/workflows.cue worker `tonky-ci`): every job on the x86_64 slots, 6 cpus and
		// 13 GB each, which the limiter sizes shards and workers to.
		workers: {
			"standard": {
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"]
				tier:            "dedicated"
				available:       2
				cost_per_min:    0.010
				cpus:            6
				memory_mb:       13312
				timeout_minutes: 90
			}
		}
	}
	workflows: {
		ci: {
			layout:   "staged"
			services: "on_demand"
			stages: [
				_preflightStage,
				_testStage,
			]
		}
	}
}
