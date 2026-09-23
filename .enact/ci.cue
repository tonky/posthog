package replay

pipeline: {
	ci: {
		concurrency: {
			max_parallel_jobs: 16
			max_total_shards:  32
		}
		strategy: "auto"
		workers: {
			"depot-16": {
				available:    1
				cost_per_min: 0.064
				cpus:         16.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 65536
			}
			"depot-4": {
				available:    4
				cost_per_min: 0.016
				cpus:         4.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 16384
			}
			"depot-8": {
				available:    2
				cost_per_min: 0.032
				cpus:         8.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 32768
			}
			"standard": {
				available:    4
				cost_per_min: 0.008
				cpus:         2.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 7168
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
