package schema

// The component fields that each declare a one-task job of the same name.
#Slots: ["lint", "fmt", "typecheck", "audit", "build", "pack", "smoke", "migrate", "schema_check", "test"]

// How enve service instances are scoped across runs and shards.
#ServiceInstanceMode: "per_run" | "per_shard" | "declared"

// Single job node within the execution DAG.
#ForecastResources: {cpus: number & >0, memory_mb: int & >0}
#ResourceForecastPolicy: {
	mode:           *"advisory" | "upward_only" | "bounded"
	min?:           #ForecastResources
	max?:           #ForecastResources
	min_attempts:   *3 | (int & >=2)
	max_age_secs:   *604800 | (int & >0)
	min_confidence: *0.95 | (number & >=0 & <=1)
	memory_margin:  *1.2 | (number & >=1)
	if mode == "bounded" {min: #ForecastResources, max: #ForecastResources}
}

#Job: {
	// Explicit locked role; omitted jobs inherit their component or nearest enve.cue.
	environment_file?: #EnvironmentFile
	name?:   string
	worker?: string
	// The CPU architecture its runner must have, or `any`. Unset, CI's plan resolves one:
	// the fleet's one architecture its `enve.lock` covers, else its outputs group's (a
	// builder and its consumers share one, chosen by when they finish: CI caches outputs
	// per architecture), else any. A pin says why (`arch_reason`).
	arch?:        #JobArch
	arch_reason?: string
	shards?:      #ShardingSpec
	max_shards?:  int & >0
	// Targets a shard keeps together, one runner process per group.
	shard_groups?: #ShardGroups
	// How a recording run gets footprints of the job's tests.
	recorder?: #Recorder
	// The recorders every footprint of the job's tests must name (enact's own: enact-trace,
	// enact-go, enact-node; or an `analysis.recorders` name). A footprint naming none of
	// one is stale and records again, as at its version bump.
	recorded_by?: [...string]
	resources?:         #ResourceSpec
	resource_forecast?: #ResourceForecastPolicy
	// What one shard takes while it records footprints (a coverage build, its linked
	// binaries): a recording shard is admitted at it, not at `resources`. Unset: the
	// recording's own calibration, then `resources`.
	record_resources?: #ResourceSpec
	// Files the job builds for the jobs naming it in `needs`, of its component or of
	// others: a run builds them once, before the first of those runs, and every shard of
	// theirs reads them; CI builds them in a job of their own and restores them in each
	// consumer. Built from the same `key` (the job's commands and tools, and the committed
	// and uncommitted content of the files its patterns match), they are up to date and
	// not built again.
	outputs?: #BuildOutputs
	// Jobs whose `outputs` this job reads: `"build"` of the same component, `"ui:build"`
	// of a component this one depends on. They build first, once per run however many
	// jobs need them; a stage selecting this job runs them too. A job building outputs
	// may need another's (a chain, never a cycle): those build before it, and its key
	// holds theirs.
	needs?: [...string]
	tasks?: [...#Task]
	// Scoped fixture acquired before the shard/job's tasks run and released on exit (E2).
	fixture?: #FixtureSpec
	// Test target selection for this job. Without one it runs whole; the `test` job
	// falls back to its component's `target_scope` (or `scoping.selector`).
	target_scope?: #TargetScope
	tools?: [...(#Tool | string)]
	// Whether running the job starts its component's services. Unset: a `jobs` entry
	// starts them; a slot job as its slot says (lint, fmt, typecheck, audit, build and
	// pack start none; smoke, migrate, schema_check and test start them). Set it false
	// for a job that runs against no service (a static check) and true for one that needs
	// them; a slot whose default is wrong is declared here, in `jobs`.
	services?: bool
	// How enve service instances are scoped for this job ("per_run", "per_shard", or "declared").
	service_instances?: #ServiceInstanceMode
	// A direct job acts on its component's own changed files: a change selects it only when
	// it touches the component itself (no dependents, no reach), it reads none of the
	// component's submodules, and it sizes as a static check (1 cpu, 512 MB) unless it
	// declares `resources`. Unset: a `jobs` entry isn't direct; the lint, fmt, typecheck and
	// audit slots are. The default `preflight` stage runs the direct jobs, `tests` the rest.
	direct?: bool
	// The job builds output its component's dependents may read (a package's `dist`,
	// generated code); simulate hints when a dependent may run before it. Unset: a `jobs`
	// entry doesn't; the build and pack slots do.
	builds?: bool
	// CI events on which this job runs (default: unset = all events, including local runs).
	events?: [...#JobEvent]
	// Optional technology override for this job (default: inherits component.technology).
	technology?: #TechnologyMode | [...#TechnologyMode]
}

#JobEvent: "pull_request" | "push" | "workflow_dispatch" | "merge_group" | "schedule"

#EnvironmentFile: string & =~"^(\\./)?([A-Za-z0-9_.-]+/)*enve\\.cue$" & !~"(^|/)\\.\\.(/|$)" & !~"/\\./"

// A job's build outputs: `paths` (repo-relative files, directories or globs it builds,
// untracked) and `key` (repo-relative patterns of every file they are built from).
#BuildOutputs: {
	paths: [string, ...string]
	key: [string, ...string]
	arch_independent?: bool
}

// Trigger configuration for pipeline activation.
#Trigger: {
	push?: {
		branches?: [...string]
		paths?: [...string]
	}
	pull_request?: {
		branches?: [...string]
		paths?: [...string]
		types?: [...#PullRequestActionMode]
	}
	schedule?: [...string]
	workflow_dispatch?: bool | *true
}

// Worker / Runner pool definition in CI
#WorkerSpec: {
	host_id?: string & =~"^[a-z0-9][a-z0-9-]{0,30}$"
	name?:    string
	preset?:  #RunnerPresetMode
	labels?: [...string]
	// Its runners' CPU architecture, for labels that don't say it (`ARM64`/`X64`, a hosted
	// `ubuntu-*` image): without either it runs no job, every job being bound to one.
	arch?:         #Arch
	cpus?:         number
	memory_mb?:    int
	max_parallel?: int
	available?:    int
	cost_per_min?: number
	// How the worker is provisioned; tasks declared on a dedicated worker never land on spot
	tier: *#WorkerTier.OnDemand | #WorkerTierMode
	// Notice window in seconds before spot reclamation (e.g. 30, 120)
	preemption_notice_sec?: int
	base_clock_ghz?:        number
	boost_clock_ghz?:       number
	boot_overhead_sec?:     number
	// Per-job preparation after startup, measured for this worker's cache cohort.
	setup_overhead_sec?: number & >=0
	// Relative single-shard execution throughput (> 0, default 1.0) for heterogeneous shard packing
	throughput?: number & >0
	// Longest a job may run on this worker before the runner kills it (a hosted
	// runner's cap): the jobs it runs time out there, `enact check` flags longer tasks
	timeout_minutes?: int & >0
	// Runners in size classes sharing each host's budget (a self-hosted fleet starting one
	// container per job): a job asks for the smallest size that fits it, by that size's
	// label besides `labels`. `available` then counts hosts; leave `cpus`/`memory_mb` out.
	pool?:        #WorkerPool
	quota_group?: string
}

// A pool worker's sizes and each host's budget: the runners a host runs at once ask at
// most `cpus` cores and `memory_mb` together.
#WorkerPool: {
	cpus:      number & >0
	memory_mb: int & >0
	// Exactly one sizing policy; quantized resources are independent integer quanta.
	({
		sizes: [string]: {cpus: number & >0, memory_mb: int & >0}
		quantization?: _|_
	} | {
		sizes?: _|_
		quantization: {
			label_prefix:       string & =~"^[A-Za-z0-9_-]+$"
			cpu_step:           1
			memory_step_mb:     1024
			runtime_reserve_mb: *1024 | int & >=0
			min: {cpus: int & >0 & <=4294967295, memory_mb: int & >0 & <=4398046510080}
			max: {cpus: int & >0 & <=4294967295, memory_mb: int & >0 & <=4398046510080}
			control: {cpus: int & >0 & <=4294967295, memory_mb: int & >0 & <=4398046510080}
		}
	})

	// What a host still runs while its dispatcher is clamped (its other load: a lane, a
	// gate): a size beyond it waits until the host is idle, so the planner places none there.
	floor?: {
		cpus:      number & >0
		memory_mb: int & >0
	}
}

#CiHistory: {
	workflow:     string & !=""
	max_runs:     int & >=1 & <=8 | *8
	max_age_days: int & >=1 & <=14 | *14
	max_bytes:    int & >=1 & <=4194304 | *4194304
}

// Global CI execution & capacity configuration
#CiConfig: {
	soft_placement?: {fallback_seconds: *15 | int & >=1 & <=15}
	history?: #CiHistory
	// Available worker / runner types in the CI environment
	workers?: [string]: #WorkerSpec
	// The worker the jobs around the stages run on (detect, summary, seeds, stage jobs
	// naming no runner). Unset, on a fleet of several architectures they ask the labels
	// every worker carries, so any host serves them; else the "standard" worker.
	control_worker?: string

	// Global concurrency limits across the pipeline
	concurrency?: {
		max_parallel_jobs?: int
	}

	// PR labels and branch prefixes that make a run skip the task cache, besides
	// `[no-cache]` in the PR title/body and the `no_cache` dispatch input.
	no_cache?: {
		labels: [...string] | *["no-cache"]
		branch_prefixes?: [...string]
	}

	// PR labels and branch prefixes that make a run re-execute what it selects without
	// reusing task or target results (`enact run --rerun`), keeping installs and build
	// outputs, besides `[rerun]` in the PR title/body. `no_cache` wins when both match.
	rerun?: {
		labels: [...string] | *["rerun"]
		branch_prefixes?: [...string]
	}
	// A trusted same-repository branch can exceed the CI budget without bypassing results.
	allow_broad?: branch_prefixes: [...string]

	// Remote object-store cache CI shares across runs. Absent (the default), generated
	// workflows carry no bucket credentials, env, steps or script branches.
	remote_cache?: #RemoteCache

	// How CI's jobs get enact and enve. Absent (the default), the repository's committed
	// builds (`bin/`). Set, one `binaries` job fetches them first.
	binaries?: #CiBinaries

	// Execution and fleet optimization scheduler settings
	scheduler?: #SchedulerSettings

	// Path to test quarantine manifest (e.g. .test_quarantine.json)
	quarantine_file?: string

	// Where the forge reads workflows from: `enact ci generate` writes there and
	// `enact check` audits the workflows checked in there.
	workflows_dir?: string | *".github/workflows"

	// Workflows in `workflows_dir` the repository keeps as data its tests read, which this
	// pipeline never runs (a fork's upstream workflows, disabled there), as
	// repository-relative paths: `enact check` reports their findings as information,
	// and fails when one is missing or is a workflow the pipeline generates.
	kept_workflows?: [...string]

	// Files a job leaves for diagnosing its failure (a browser test's screenshots), as
	// globs, absolute or repository-relative: each job uploads them with its telemetry.
	diagnostic_paths?: [...string]

	// The most one run may plan (`enact plan --budget` exits 3 over it): tests run
	// without a trace narrowing them (untraced, aged, or a suite run whole by its
	// listing), and the fleet forecast's wall time.
	budget?: {
		// Guard CI detect before it emits any matrix; other pipelines stay opt-in.
		enforce:        bool | *false
		untraced_tests: int & >=0 | *100
		wall_minutes:   int & >0 | *30
	}
}

// An opt-in remote cache: enve closures (pulled on a miss, pushed on save events), task
// results, browser archives, database snapshots and telemetry reports.
#RemoteCache: {
	// The only backend so far: `remote_cache: {}` opts in.
	backend: #RemoteCacheBackendMode
	// Forge secrets holding the bucket URL and its credentials.
	// Optional `read_*` restricts read-only/PR steps to an Object Read Only token so primary
	// write keys stay confined to default-branch save steps; optional `pr_*` scopes same-repo
	// PR writes to a prefix-restricted token.
	secrets: {
		bucket:                  string | *"ENACT_R2_BUCKET"
		access_key_id:           string | *"ENACT_R2_ACCESS_KEY_ID"
		secret_access_key:       string | *"ENACT_R2_SECRET_ACCESS_KEY"
		read_access_key_id?:     string
		read_secret_access_key?: string
		pr_access_key_id?:       string
		pr_secret_access_key?:   string
	}
	// Where the bucket serves its objects to anyone, at their keys (an R2 public domain,
	// e.g. "https://pub-<id>.r2.dev"): planning reads reach maps there, unsigned, when no
	// credentials are set.
	public_url?: string
	// The public key enve signs the bucket's closures with ("name:base64", not a secret).
	// CI trusts it (`ENVE_TRUSTED_PUBLIC_KEYS`): pulls check those signatures, and a runner's
	// shared enve mirror takes the closures in. Unset, pulls skip signature checks.
	public_key?: string
	// Fallback `owner/repo` key for reach maps in the remote cache when `origin` points to a
	// developer's fork or upstream rather than the repository publishing the maps.
	repo?: string
	// Default showcase/integration branch head in the remote cache that `auto_pull` and
	// `enact reach store pull` consult alongside the current and default branches.
	branch?: string
}

// enact and enve built from the repository's own sources: one CI job builds them into `bin/`
// ahead of the others, which install them from its artifact instead of the committed builds.
// Paths are relative to the repository holding the workflows (a project inside it doesn't
// move them).
#CiBinaries: {
	// The command putting `bin/enact` and `bin/enve` in place, run in bash from the
	// repository root; it fails when no build matches the checkout.
	fetch: string
	// What the command reads (its sparse checkout).
	inputs: [string, ...string]
	// Environment variables the command reads, each from the forge secret it names.
	secrets?: [string]: string
	// The fetch job's time limit, in minutes.
	timeout_minutes: int & >0 | *5
}

// Execution and fleet optimization scheduler configuration
#SchedulerSettings: {
	makespan_tolerance?:     number | *1.25
	default_task_sec?:       number | *45.0
	avg_ram_ratio?:          number | *0.75
	cpu_headroom_cores?:     number | *0.5
	ram_headroom_pct?:       number | *0.15
	allow_service_sharing?:  bool | *true
	max_matrix_size?:        int | *64
	batch_size?:             int | *16
	default_shm_mb?:         int | *2048
	default_db_connections?: int | *20
}

// Repository-wide toolchains installed before running tasks: by CI's install steps, and
// once per local `enact run` before any shard (the prepare phase). `install`
// replaces the package manager's frozen-lockfile install. `outputs` are repository-relative
// paths or globs the install leaves behind; a local run installs again when one is missing,
// whatever its inputs. Defaults: node_modules/.modules.yaml (pnpm),
// node_modules/.package-lock.json (npm), yarn's install state, node_modules (bun),
// .venv/pyvenv.cfg (python); `[]` declares none.
#Toolchain: {
	node?: {
		package_manager: "pnpm" | "npm" | "yarn" | "bun"
		install?:        string
		env?: [string]: string
		outputs?: [...string]
		workspaces?: [...string]
	}
	python?: {
		package_manager?: "uv" | "poetry" | "pip"
		install?:         string
		env?: [string]: string
		outputs?: [...string]
		workspaces?: [...string]
	}
}

// Declarative filesystem scope specification (sparse checkout cone & audit filtering).
//
// Path patterns (include, ignore, a component's watch_paths, target-rule match and
// tests, task filters, scoping domain_roots) follow one
// rule: a glob relative to the repository root, always anchored. `*`, `?`, `[...]` and
// `{a,b}` match within one path segment; `**` matches any number of segments, so `**/`
// is the only way to match at any depth (`**/.vscode/**`). A literal path names itself
// and everything below it: "docs" and "docs/**" are the same directory. Rejected: a
// leading "/" or "./", a trailing "/", a leading "!" and an empty pattern. Sparse
// checkouts (git cone mode) take the directory holding a pattern's matches: whole for a
// literal path or a "**" ("web/src/**/*.ts" checks out "web/src"), only its own files for
// a glob in the last segment ("tests/*.go" checks out the files directly in "tests", not
// "tests/integration"). Fields that hand patterns to another tool keep that tool's syntax: CI
// trigger `paths`, cache `key` files (hashFiles), artifact paths.
#WorkspaceScope: {
	// Paths every checkout in scope needs: the sparse baseline. An include covers no
	// file: a file no component owns (by root or watch_paths) is unmapped and selects
	// every component, wherever it is included. A component's include adds to its root
	// and watched paths in its cone, never replaces them.
	include?: [...string]
	// Paths no task reads: they are no component's (a change to one selects nothing,
	// the audit counts them ignored) and leave the cone. One exception: a path a
	// component's watch_paths names literally (no glob) stays that component's. A root
	// or a glob watch never outranks an ignore. The pipeline's and every component's
	// ignores apply repository-wide, as do "**/.gitignore" and "**/.gitattributes".
	ignore?: [...string]
	include_dependencies?: bool | *true
	// Command printing extra cone paths
	resolver?: #SelectorSpec
	// Commands printing cone paths; `replace` swaps a component's cone (component level only)
	hooks?: #ScopeHooks
	// Git submodules the tasks read (e.g. "e2e/test-assets"): added to the cone and
	// fetched shallow at the pinned commit. Undeclared submodules are never fetched.
	submodules?: [...string & =~"^[^/\\s]\\S*$" & !~"(^|/)\\.\\.?(/|$)"]
}

#ScopeHooks: {
	pre?: [...string] | string
	replace?: string
	post?: [...string] | string
}

// Test target selection for a component: rules map changed files to targets.
#TargetScope: {
	// When an engine, command or hook was handed changed files and selected no target:
	// run everything ("all", unless the traces show nothing reached), or nothing. Files
	// nothing was handed (ignored, docs, other components') select nothing either way.
	fallback?: #SelectorFallbackMode | *#SelectorFallback.All
	// Target that stands for "the whole component" (e.g. an addon's test tag)
	default_target?: string
	rules?: [...#TargetRule]
	hooks?: #ScopeHooks
	// The rules' commands and the hooks need the job's installed environment (jest's
	// module graph needs node_modules): the planners, which run before it is installed (CI's
	// detect job), schedule the job without running them, sharded as its whole suite, and
	// the job selects after its prepare step; a shard left nothing is skipped.
	select_in_job?: bool | *false
	// The test runner whose collection configuration (`pytest.ini`, `norecursedirs`,
	// `conftest.py`) the suite follows.
	runner?: string
	// Path patterns (see #WorkspaceScope) naming the suite's test files (e.g.
	// "e2e/src/specs/server/**/*.e2e-spec.ts").
	// A reach map prunes the component only when it traced all of them; undeclared,
	// every test-named file under the component's roots counts.
	tests?: [...string]
	// Path patterns naming tests under the component's roots its suite leaves out:
	// another suite runs them (`enact check` flags one none does).
	exclude?: [...string]
	// A regex over the names of the tests (a target's part after `::`, subtests left out)
	// its runner picks of its files (`go test -run '^TestIntegration'`): its files' tests
	// named otherwise are another suite's. A suite's recording takes only these, so two
	// suites sharing a file each record and keep their own tests' footprints.
	test_names?: string
	// A regex over the names of its files' tests another suite runs (`go test -short`
	// skipping `TestIntegration…`).
	exclude_test_names?: string
	// Tests under the component's roots a dependent's job runs instead: those reading what
	// the dependent builds, which can't be an edge of the graph (a cycle). They leave this
	// suite and join `to`'s `job` (default "test"); changes to `to`, and to its
	// dependencies (this component included), select them.
	handoff?: [...#TestHandoff]
	// Tests under the component's roots no suite runs, with why (they need a container
	// runtime the environment lacks, a vendor account): the suite leaves them out, and
	// `enact check` lists them (TEST_NOT_RUN) instead of flagging a TEST_OWNERSHIP_GAP.
	not_run?: [...#NotRun]
	// Tests of the suite only one architecture runs (a wheel the other lacks), with why: CI
	// runs them in an entry of their own pinned to `arch`, and the rest of the suite on any.
	arch_exclusions?: [...#ArchExclusion]
	// Another suite ("<component>:<job>") owning the same tests, whose footprints this
	// suite takes as its evidence: the same tests run against another database or runtime
	// (forgejo's integration-mysql takes "integration:test"'s). Its own rules still decide
	// its own files (a full_component rule names code only it runs), a file the other
	// suite's traces never read runs it whole, and it records no footprints of its own.
	footprints_from?: string & =~"^[^:\\s]+:[^:\\s]+$"
	// The custom Go build tags the suite's `go test` passes (`-tags`; "race" with `-race`):
	// a `_test.go` file whose name and `//go:build` constraint no build with them satisfies,
	// on any platform, holds none of its tests (go/build semantics: platform tags, `unix`,
	// `cgo`, `gc` and `goN.M` are a build's own; any other tag only these set).
	go_tags?: [...string]
	// Inferred reach for the suite's tests no trace ran: each is predicted from its
	// stratum's most alike traced tests. "shadow" runs them all and reports what a
	// prediction would skip; "on" skips them, for the strata `enact reach infer
	// --validate` measured at `min_recall` (`.enact/trace-infer.json`).
	inference?: #Inference
	// Path patterns naming files outside the suite's graph that its runner or boot reads
	// incidentally: a traced reader still runs when one changes, but simulate doesn't flag
	// the read as REACH_UNDECLARED_INPUT and a change to it alone doesn't select the
	// suite's untraced tests.
	incidental_reads?: [...string]
	// Shard partitioning order: "balanced" (LPT greedy bin-packing) or "contiguous"
	// (contiguous min-max block partitioning that preserves test declaration order).
	shard_order?: #ShardOrder
	// Parent test targets whose recorded subtests may be split across adjacent shards.
	split_targets?: [...string]
}

#TestHandoff: {
	// A component depending on this one, directly or through others.
	to:   string
	job?: string | *"test"
	// Path patterns naming the tests, under this component's roots.
	tests: [...string] & [_, ...]
	// When true, the receiving suite dispatches handed-off targets in this donor component's
	// `root` directory with target paths rewritten relative to the donor's `root`.
	run_in_owner_root?: bool | *false
}

#ArchExclusion: {
	// The one architecture that runs them.
	arch: #Arch
	// Path patterns naming the tests, under the component's roots.
	tests: [...string] & [_, ...]
	reason: string & =~"\\S"
}

#NotRun: {
	// Path patterns naming the tests, under this component's roots.
	tests: [...string] & [_, ...]
	reason: string & =~"\\S"
}

#Inference: {
	mode?:       *"off" | "shadow" | "on"
	min_recall?: number & >0 & <=1 | *0.98
	neighbours?: int & >=1 | *3
}

#TargetRule: {
	id?: string
	// Path patterns (see #WorkspaceScope) naming the changed files the rule takes
	match: [...string] | string
	// Built-in impact analyzer for the matching files: `reach` selects the tests the
	// trace reach map says execute the files; `go` selects tested Go packages importing
	// the changed packages; `watch_annotations` selects spec files whose `// @watch`
	// globs match the changed files.
	engine?: "python" | "typescript" | "reach" | "go" | "watch_annotations"
	// Package regex filters for `engine: "go"` (matched against Go package import paths).
	keep?: [...string] | string
	drop?: [...string] | string
	// Global file globs for `engine: "watch_annotations"` that trigger a full spec run.
	global_files?: [...string] | string
	// Command printing targets for the matching files ({changed_files})
	command?: string
	// Rules see the component's own changed files and its dependencies'.
	// "ignore" says the matching files reach no test; it is decisive, so no other rule
	// (full_component included) sees them. "full_component" runs the whole suite when a
	// file matches, over any selecting rule. A changed file of the component no rule
	// matches, other than a doc, runs the whole suite; a dependency's file no rule
	// matches does too, unless the trace reach map answers for it.
	action?:      "full_component" | "ignore"
	granularity?: #TargetGranularityMode
}

// Complete Pipeline specification.
#Pipeline: {
	name:         string
	description?: string
	triggers?:    #Trigger
	env?: [string]: string

	// Declarative CI & Worker Pool Configuration
	ci?: #CiConfig

	toolchain?: #Toolchain
	tools?: [...(#Tool | string)]

	// Pipeline-wide cache definitions
	caches?: [string]: #Cache & {
		used_by?: jobs?: [...#jobName]
		...
	}

	// Shared infrastructure services across components
	services?: [string]: #ServiceSpec

	// Global filesystem cone for sparse checkout and unmapped audit
	workspace_scope?: #WorkspaceScope

	// Where a run's services run. "per_run": an enve instance of the run's own, every port
	// a free one (tasks read ports from ENVE_SERVICE_<NAME>_PORT), so concurrent runs,
	// checkouts and machines never collide. "per_shard": when `shards > 1`, each shard spawns
	// with its own isolated `<instance>-s<shard>` enve service instance. "declared": enve's
	// default instance on the ports enve.cue declares, for code that hardcodes them; a
	// checkout's runs that need services take turns.
	service_instances?: *"per_run" | #ServiceInstanceMode

	// Dependency conventions and Python test selection
	analysis?: #Analysis

	// Dynamic component discovery command (optional)
	components_discovery?: string | [...string]

	// Components in this pipeline/monorepo
	components?: [string]: #Component

	// Every job name some component has: its slots, its `jobs` and its enve service's
	// actions. Stages and caches reference jobs through it (`pipeline.#jobs.test`), so a
	// misspelt name fails evaluation. Equality-only comprehensions: cue-rs cannot yet
	// test fields against `_|_`.
	#jobs: {
		for s in #Slots {(s): s}
		for _, c in components for k, v in c {
			if k == "jobs" for n, _ in v {(n): n}
			if k == "service" for a, w in v {
				if a == "test" || a == "lint" {(a): a}
				if a == "tasks" for t, _ in w for s in #Slots if t == s {(t): t}
			}
		}
	}

	// Closed set of valid job names across all components in this pipeline.
	#jobName: or([for k, _ in #jobs {k}])

	// Granular workflows (local, ci, nightly, etc.)
	workflows?: [string]: #Workflow & {
		stages?: [...{
			select?: [...(#jobName | #TaskSelector)]
			...
		}]
		...
	}
}

// Language analysis: repository conventions the dependency scanner follows, shard
// balancing and what reach maps record.
#Analysis: {
	dependencies?: #DependencyRules
	// Per-test duration maps (test id → seconds, or pytest timings) that balance shards,
	// relative to the repository and component roots. `*` may stand in a file name; `.gz`
	// files are decompressed. Default: [".test_durations"] (pytest-split's file).
	durations?: [...string]
	// Files a build writes (git-ignored, never in a diff) and the sources it reads: a
	// change to one of `inputs` reaches every traced test that read one of `outputs`.
	derived?: [...#DerivedOutputs]
	// Whether `enact run` records footprints of the tests it runs that the reach map lacks
	// or holds stale, through the job's recorder ($ENACT_FOOTPRINT_DIR): "auto" (outside
	// CI; on CI where ENACT_RECORD=auto) or "off".
	record?: "auto" | "off"
	// The current version of each footprint recorder the jobs run, by name: what a
	// recorder writes as its map's `"recorder": "<name>/<version>"`. A footprint one
	// recorded at another version is stale (`enact reach stale`) and records again.
	recorders?: [string]: string
	// The suites ("<component>:<job>") whose footprints hold a source file (python,
	// js/ts, go, rust) by its code form, whole-line comments and blank lines left out,
	// rather than its bytes: an edit of only those neither ages nor breaks them. Set per
	// suite after review: a test that reads source as data (license headers, `# noqa`
	// counts, line-number snapshots) must not be here. Default: none.
	code_form?: [...string]
	// Set after measuring that the pipeline's Jest runs record the same footprints with a
	// warm transform cache as with a cold one (FINDINGS#F-js-jest-transform-cache-keeps-reads):
	// their `enact-node/2` footprints (Jest's runtime read, no vitest) then stay current.
	// Default: false, and they record again.
	jest_cache_keeps_reads?: bool
}

#DerivedOutputs: {
	// Repository-relative globs (`*` stops at `/`, `**` doesn't). `outputs` is not empty,
	// nor are both `inputs` and `layout`.
	outputs: [...string]
	// Files under `outputs` this rule does not write (another rule's outputs under the same dir).
	exclude_outputs?: [...string]
	inputs?: [...string]
	// Files whose addition or deletion (not edit) rebuilds the outputs: a generator that
	// lists them (file-based routes), so editing one reaches only its own readers.
	layout?: [...string]
	// Files under `inputs` or `layout` the build leaves out (a package's tests).
	exclude?: [...string]
	// The `inputs` the build compiles function by function into outputs whose source
	// maps name them (tsup, tsc, esbuild: no function body inlined across modules), not
	// config (tsconfig, package.json, a bundler config whose plugins run at build time).
	// A body edit of one reaches a test whose enact-node recorder placed everything it
	// ran of the rule's outputs in their functions only when it ran an edited function.
	mapped?: [...string]
	// 1-to-1 per-file transpilation roots (`from` -> `to`, e.g. `tsc` without a bundler and
	// `preserveConstEnums: true`): modifying `<from>/<stem>.<ext>` changes runtime JS/map
	// outputs under `<to>/` only at `<to>/<stem>.{js,mjs,cjs,jsx}{,.map}`.
	transpiled?: [...#TranspiledStem]
}

#TranspiledStem: {
	from: string
	to: [string, ...string]
}

#DependencyRules: {
	// Manifests in a component root whose `key: [...]` lists name the components it depends
	// on (e.g. `{file: "__manifest__.py", keys: ["depends"]}`); they also mark package roots.
	manifests?: [...{file: string, keys: [...string]}]
	// Module prefixes followed by a component name (e.g. "pkg.plugins." for `pkg.plugins.<name>`)
	import_prefixes?: [...string]
	// Specifier prefixes followed by a component name (e.g. "@" for `@<name>/path`)
	asset_prefixes?: [...string]
}
