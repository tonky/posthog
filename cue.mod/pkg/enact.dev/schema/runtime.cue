package schema

import "time"

// Accepts standard human-readable duration strings with explicit units (e.g. "5s", "500ms", "1m")
#Duration: time.Duration & !~"^-"

// Hardware resource requirements
#ResourceSpec: {
	// e.g. 2, 4, 8 cores
	cpus?: number
	// e.g. 4096 (4GB), 16384 (16GB)
	memory_mb?: int
	// shared memory tmpfs size in MB
	shm_mb?: int
	gpu?:    #GpuTierMode | *#GpuTier.None
}

// Runner specification: the platform and toolchain a component runs on, and the compute
// and CI labels it needs.
#RunnerSpec: {
	platform: #PlatformMode | *#Platform.LinuxAmd64
	// e.g. "go:1.22", "rust:1.85"
	toolchain?: string
	resources?: #ResourceSpec
	// CI runner labels; without them CI picks a `ci.workers` entry that fits `resources`.
	external?: labels?: [...string]
}

// enact's part of a service: how CI and the runner use it. enve's `#Service` is open to
// preset keys, so enact's own keys live in this one closed block.
#EnactService: close({
	// What the service is. Connection variables, database forking and readiness round
	// trips depend on it; enact never infers it from a name, package or port.
	kind?:      #ServiceKindMode
	mode?:      #ServiceTransportMode
	placement?: #ServicePlacementMode
	// The Redis service owning the unprefixed REDIS_* variables when a component uses several.
	primary?: bool
	// Postgres: the template database each shard forks from, and the command that builds it.
	template?:      string
	template_init?: string
	// Postgres: pre-built dump CI downloads from the remote cache bucket
	// (`snapshots/<name>`) into `~/.cache/enact/snapshots/` before the tasks run.
	snapshot?: close({name: string})
	// Postgres: extra databases created next to `database`.
	databases?: [...string]
	// Object storage: buckets created before the tasks run.
	buckets?: [...string]
})

// A service a component needs: enve's service keys (what runs), plus the `enact` block.
//
// Deliberately not `enveschema.#Service & {...}`: enve validates the declarations it
// runs, enact's loader types every key it reads, and unifying enve's recursive,
// disjunction-heavy `#Service` again at each use made evaluation grow exponentially.
#ServiceSpec: {
	enact?: #EnactService
	...
}

// Presets: a kind with its well-known port and transport.
#PostgresService: #ServiceSpec & {
	port: *5432 | int
	enact: kind: #ServiceKind.Postgres
}

#RedisService: #ServiceSpec & {
	port: *6379 | int
	enact: kind: #ServiceKind.Redis
}

#ClickHouseService: #ServiceSpec & {
	port: *8123 | int
	enact: {kind: #ServiceKind.ClickHouse, mode: #ServiceTransport.Loopback}
}

#KafkaService: #ServiceSpec & {
	port: *9092 | int
	enact: {kind: #ServiceKind.Kafka, mode: #ServiceTransport.Loopback}
}

#TemporalService: #ServiceSpec & {
	port: *7233 | int
	enact: {kind: #ServiceKind.Temporal, mode: #ServiceTransport.Loopback}
}

#ObjectStorageService: #ServiceSpec & {
	port: *19000 | int
	enact: {kind: #ServiceKind.ObjectStorage, mode: #ServiceTransport.Loopback}
}

#HttpService: #ServiceSpec & {
	enact: {kind: #ServiceKind.Http, mode: #ServiceTransport.Loopback}
}

// Declarative cache: what to keep between runs, what invalidates it and who uses it.
// CI derives the key `<id>[-<version>]-<os>[-<task>]-<hash of key files>` and restores the
// newest entry with the same prefix on a miss.
#Cache: {
	name?: string
	paths: [...string]
	// globs whose content hash invalidates the cache
	key?: [...string]
	// bump to drop every existing entry
	version?: string
	// `task`: each CI task (matrix entry or stage) keeps its own entry.
	scope:     *"shared" | "task"
	tier:      *#CacheTier.Tiered | #CacheTierMode
	mode:      *#CacheMode.ReadWrite | #CacheModeValue
	endpoint?: string
	backend?:  #CacheBackendMode
	// Tasks that read or write the cache; absent means every task. Both lists narrow the match.
	used_by?: {
		components?: [...string]
		// job names, e.g. [pipeline.#jobs.typecheck]
		jobs?: [...string]
	}
}

// Browsers a component's tests drive. CI restores `path` from a cache keyed on
// engine, version and `key` files, optionally hydrating a miss from `artifact`
// (a `.tar.zst` of `path` in the remote cache bucket), and exports `path` as `env`.
#Browsers: {
	engine:   "chromium" | "firefox" | "webkit" | string
	path:     string
	env?:     string
	version?: string
	key?: [...string]
	artifact?: string
}
