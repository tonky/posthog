package replay

import "enact.dev/schema"

pipeline: schema.#Pipeline & {
	toolchain: node: package_manager: "pnpm"
	ci: {
		no_cache: {
			labels: ["no-cache", "showcase"]
			branch_prefixes: ["showcase/"]
		}
		concurrency: {
			max_parallel_jobs: 16
		}
		workers: {
			"standard": {
				available:    16
				cost_per_min: 0.008
				cpus:         4.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 16384
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
