package schema

// Architectural relationship between components.
#Relationship: {
	// target component or service reference (e.g. components.quill, pipeline.services.postgres, or "quill")
	target:    _
	// e.g. "Calls HTTP API", "Compiles against"
	title?:    string
	protocol?: #ProtocolMode | string
}

// A slot's command, or the whole task
#SlotTask: string | #Task

// Declarative component with LikeC4 architecture metadata & codebase boundaries.
#Component: {
	environment_file?: #EnvironmentFile
	// Identification & LikeC4 metadata
	name?:        string
	title?:       string
	description?: string
	kind?:        #ComponentKindMode
	domain?:      string
	tags?: [...string]
	// Architectural technology classification (strongly typed enum or list of enums). It
	// also picks the toolchain installs the component's tasks get (node, python): none
	// declared, its dependencies' technologies; none there either, no install.
	technology?: #TechnologyMode | [...#TechnologyMode]
	// Browsers the component's tests drive; CI provisions them for its matrix entries.
	browsers?: #Browsers
	// Where its Cargo builds land, for CI's Rust cache. Default: a Rust component's root is
	// its Cargo workspace, building into `<root>/target` (or the env's CARGO_TARGET_DIR).
	// Declaring it gives any component the cache (a Node package building a napi addon).
	cargo?: #Cargo

	// Architectural dependencies
	uses?: [...#Relationship]

	// Codebase boundaries & change detection
	// e.g. "pkg/core", "services/api"
	root?: string
	// files the component owns besides its root's tree, as path patterns anchored at the
	// repository root (see #WorkspaceScope for the rule). A component owns its root's
	// tree and these together: a change to either selects it, and both make its cache
	// key. The component's checkout holds them, its dependents' checkouts don't.
	watch_paths?: [...string]
	// component dependencies (accepting component references or string names)
	depends_on?: [..._]

	// The enve service this component is: its test, lint and tasks become the component's jobs.
	service?: #ServiceSpec

	// Multi-level test and blast radius scoping rules
	scoping?: #ScopingRules

	// Declarative filesystem cone for sparse checkout
	workspace_scope?: #WorkspaceScope

	// Test target selection for the `test` job; another job declares its own
	// (`jobs.<name>.target_scope`).
	target_scope?: #TargetScope

	// Slots: a one-task job named after the slot, as a command or a #Task. A job name
	// set by a slot and by `jobs` (or the enve service) is an error.
	lint?:         #SlotTask
	fmt?:          #SlotTask
	typecheck?:    #SlotTask
	audit?:        #SlotTask
	build?:        #SlotTask
	pack?:         #SlotTask
	smoke?:        #SlotTask
	migrate?:      #SlotTask
	schema_check?: #SlotTask
	test?:         #SlotTask

	// Runtime execution requirements
	runner?: #RunnerSpec
	// Every job's resources, worker and CPU architecture, unless the job declares its own.
	resources?: #ResourceSpec
    resource_forecast?: #ResourceForecastPolicy
	worker?:    string
	arch?:      #JobArch
	// Why it pins `arch` (required with x86_64 or aarch64).
	arch_reason?: string
	// The `test` job's shards, shard groups, recorder and recording size, however that job
	// is declared (the `test` slot, the service's `test` or `jobs.test`). Set with no
	// `test` job, or in `jobs.test` too, fails to load (cue-rs can't test fields against
	// `_|_`).
	shards?:           #ShardingSpec
	max_shards?:       int & >0
	shard_groups?:     #ShardGroups
	service_instances?: #ServiceInstanceMode
	recorder?:         #Recorder
	recorded_by?: [...string]
	record_resources?: #ResourceSpec
	// Services the component's tasks need, keyed by name or listed with `name`.
	services?: {[string]: #ServiceSpec} | [...#ServiceSpec & {name: string}]
	caches?: [string]:  #Cache
	toolchain?: #Toolchain
	tools?: [...(#Tool | string)]

	// Task definitions for this component (legacy or granular jobs)
	jobs?: [string]: #Job
}
