package schema

// Architectural technology tag.
#TechnologyTag: #Technology.Go | #Technology.Rust | #Technology.TypeScript | #Technology.Python | #Technology.Docker | #Technology.Infra | #Technology.Postgres | #Technology.Redis | #Technology.ClickHouse | #Technology.Kafka | string

// Architectural relationship between components.
#Relationship: {
	target:    _ // target component or service reference (e.g. components.quill, components.infra.services.postgres, or "quill")
	title?:    string // e.g. "Calls HTTP API", "Compiles against"
	protocol?: #Protocol.Sql | #Protocol.Http | #Protocol.Grpc | #Protocol.Tcp | #Protocol.Kafka | #Protocol.Ipc | #Protocol.Redis | string
}

// Declarative component with LikeC4 architecture metadata & codebase boundaries.
#Component: {
	// Identification & LikeC4 metadata
	name:        string
	title:       string
	description?: string
	technology:  #TechnologyTag
	tags?:       [...string]

	// Architectural dependencies
	uses?: [...#Relationship]

	// Codebase boundaries & change detection
	root:                 string        // e.g. "pkg/core", "services/api"
	watch_paths:          [...string]   // file globs triggering this component
	depends_on:           [..._]        // component dependencies (accepting component references or string names)
	dependsOnComponents?: [..._]        // explicit alias for compile/code dependencies

	// Strongly typed direct enve Service binding
	service?: _

	// Multi-level test and blast radius scoping rules
	scoping?: #ScopingRules

	// Database schema migrations verification
	migrations?: #MigrationSpec

	// Code generation & contract drift verification
	codegen?:  [string]: #CodegenSpec
	contract?: #ContractSpec

	// Static analysis & verification tasks (zero services required)
	lint?:      _
	fmt?:       _
	typecheck?: _
	audit?:     _
	build?:     _

	// Direct test specifications (single command/task or map of phases like unit/integration)
	test?: _

	// Runtime execution requirements
	runner?:     #RunnerSpec
	resources?:  #ResourceSpec
	shards?:     int | "auto"
	max_shards?: int
	worker?:     string
	services?:  {[string]: _} | [..._]
	secrets?:   [string]: #SecretSpec
	caches?:    [string]: #CacheSpec

	// Task definitions for this component (legacy or granular jobs)
	jobs?: [string]: #Job
}
