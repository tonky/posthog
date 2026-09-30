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
	// Identification & LikeC4 metadata
	name?:        string
	title?:       string
	description?: string
	tags?: [...string]
	// `infra` components provide shared services: they start first and get the
	// infrastructure layout in the UI.
	technology?: string
	// Browsers the component's tests drive; CI provisions them for its matrix entries.
	browsers?: #Browsers

	// Architectural dependencies
	uses?: [...#Relationship]

	// Codebase boundaries & change detection
	// e.g. "pkg/core", "services/api"
	root?: string
	// file globs triggering this component
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
	runner?:     #RunnerSpec
	resources?:  #ResourceSpec
	shards?:     #ShardingSpec
	max_shards?: int & >0
	worker?:     string
	// Services the component's tasks need, keyed by name or listed with `name`.
	services?: {[string]: #ServiceSpec} | [...#ServiceSpec & {name: string}]
	caches?: [string]:  #Cache
	tools?: [...(#Tool | string)]

	// Task definitions for this component (legacy or granular jobs)
	jobs?: [string]: #Job
}
