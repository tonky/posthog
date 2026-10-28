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
		// Each job asks for the smallest runner size it fits on ibp8; concurrent runners
		// share its host budget (agentic/KNOWLEDGE.md tonky-ci).
		workers: {
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
				_preflightStage,
				_testStage,
			]
		}
	}
}
