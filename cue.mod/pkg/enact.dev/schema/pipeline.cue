package schema

// Execution step within a job.
#Step: {
	name?:   string
	run?:    string
	uses?:   string
	with?:   [string]: string
	env?:    [string]: string
	timeout?: int // seconds
}

// Single job node within the execution DAG.
#Job: {
	name?:      string
	worker?:    string // Reference to a worker defined in ci.workers
	command?:   string // Shorthand for single execution command
	needs?:     [...string] // dependencies on other jobs
	runner?:    #RunnerSpec
	services?:  [string]: #ServiceSpec
	env?:        [string]: string
	shards?:     int | "auto"
	max_shards?: int
	resources?:  #ResourceSpec
	artifacts?: #ArtifactSpec
	steps?:     [...#Step]
	hooks?: {
		on_success?: [...#Step]
		on_failure?: [...#Step]
		always?:     [...#Step]
	}
}

// Artifact capture specification.
#ArtifactSpec: {
	paths: [...string]
}

// Trigger configuration for pipeline activation.
#Trigger: {
	push?: {
		branches?: [...string]
		tags?:     [...string]
		paths?:    [...string]
	}
	pull_request?: {
		branches?: [...string]
		paths?:    [...string]
	}
	schedule?: [...string] // cron expressions
}

// Worker / Runner pool definition in CI
#WorkerSpec: {
	name?:         string
	labels:        [...string]             // e.g. ["ubuntu-latest"] or ["depot-ubuntu-24.04-8"]
	cpus:          number                  // e.g. 2.0, 4.0, 8.0, 16.0
	memory_mb:     int                     // e.g. 7168, 16384, 32768, 65536
	max_parallel?: int                     // Max concurrent VMs allowed in GitHub Actions for this pool
	available?:    int                     // Available concurrent worker capacity of this type in CI
	cost_per_min?: number                  // Cost in USD per runner minute for cost estimations
}

// Global CI execution & capacity configuration
#CiConfig: {
	// Available worker / runner types in the CI environment
	workers?: [string]: #WorkerSpec

	// Global concurrency limits across the pipeline
	concurrency?: {
		max_parallel_jobs?: int            // Emitted as strategy.max-parallel in GHA matrix
		max_total_shards?:  int            // Max concurrent test shards across all matrix jobs
	}

	// Strategy for execution:
	// - "matrix": horizontal multi-VM distribution (each shard in a separate VM)
	// - "packed": vertical VM packing (multiple shards inside a high-spec VM)
	// - "auto": chooses based on resource demands (lightweight -> matrix; heavy -> high-spec packed)
	strategy?: "auto" | "matrix" | "packed" | *"auto"
}

// Complete Pipeline specification.
#Pipeline: {
	name:        string
	description?: string
	triggers?:   #Trigger
	env?:        [string]: string

	// Declarative CI & Worker Pool Configuration
	ci?: #CiConfig

	// Shared infrastructure services across components
	services?: [string]: #ServiceSpec

	// Components in this pipeline/monorepo
	components: [string]: #Component

	// Global jobs not tied directly to a single component
	jobs?: [string]: #Job
}
