package schema

// Target file matching and empty set evaluation filter. `include` and `exclude` are
// path patterns (see #WorkspaceScope for the rule), anchored at the repository root:
// "*.json" is the root's JSON files, "**/*.json" every one. `on_empty`: when it matches
// none of the component's changed files the task is skipped (a job whose every task
// skipped ran nothing and ends skipped), passes (`pass`: the job passes), fails, or runs
// on all of them (`run_all`). The filter judges only the component's own changes: when
// anything else reaches the job (`--all`, `--updated`, a dependency's change, an unmapped
// file, a file its tests read, outputs it builds) the task runs.
#FileFilter: {
	include: [...string]
	exclude?: [...string]
	on_empty: *#EmptyPolicy.Skip | #EmptyPolicyMode
}

// Task-level build-once stamp configuration: skips command execution when input
// files and declared outputs match the last stamp.
#TaskOnce: {
	key?: string
	inputs: [...string] & [_, ...]
	outputs?: [...string]
}

// One command a job runs
#Task: {
	name?: string
	// e.g. "python tools/snob.py {changed_files}" or "go list -test {changed_files}".
	// Required and non-empty: enact runs no default command in its place.
	command: string
	// Working directory override relative to the repository root (e.g. "." for repo root).
	dir?: string
	// Named host-scoped cross-process flock mutex acquired around task command execution.
	lock?: string
	// Input/output stamp guard skipping command execution when inputs and outputs match.
	once?: #TaskOnce
	// Snapshot worktree state before the task command and fail if the command modifies or
	// leaves new untracked files (either `true` across the repo or restricted to path globs).
	expect_no_drift?: bool | [...string]
	// Create an isolated temporary HOME / XDG_* directory for the duration of the task.
	isolate_home?: bool
	shell?:  #ShellMode
	env?: [string]: string
	// Variables removed from the task's environment, e.g. the injected service
	// connection variables for a task that runs against its own throwaway database.
	unset_env?: [...string]
	// e.g. "10m"
	timeout?: #Duration
	filter?:  #FileFilter
	caches?: [...#Cache]
	// Exit codes meaning the command broke rather than its tests failed (pytest's
	// 2/3/4: interrupted, internal or usage error). Such an exit stops the whole run at
	// once, naming it; any other non-zero exit is a test failure.
	error_exit_codes?: [...int]
	// Services the command uses outside any test (a setup script's `psql`), by name or
	// `enact.kind`. No test footprint records them, so a run narrowing its services to its
	// targets' recorded ones keeps these.
	services?: [...string]
}

// Declarative test target selector specification
#SelectorSpec: {
	// Command that accepts changed files and outputs resolved test targets
	command:   string
	fallback?: #SelectorFallbackMode | *#SelectorFallback.All
	timeout?:  (int & >0) | #Duration | *10
	// "file" collapses path::Class::test targets to their file so shards run whole
	// files in their own order (pytest-split parity); "item" keeps them as selected.
	granularity?: #TargetGranularityMode | *#TargetGranularity.Item
	// Size shards to the selected targets
	adaptive_shards?: bool | *true
}

// Multi-level test and blast radius scoping specification
#ScopingRules: {
	// e.g. #ScopingSelector.PythonSnob or custom selector
	selector?: #ScopingSelectorMode | #SelectorSpec | string
	// Directories the component's sparse cone adds, as path patterns
	domain_roots?: [...string]
	// Regex patterns in tests requiring running microservices
	service_markers?: [...string]
}

// Scoped per-shard or per-job fixture lifecycle contract (E2).
#FixtureScope: "shard" | "job"

#FixtureSpec: {
	scope?:   *"shard" | #FixtureScope
	setup:    string
	release?: string
	timeout?: (int & >0) | #Duration | *60
	// Required background services that must be ready before setup runs.
	services?: [...string]
	// Repository-relative input globs contributing to fixture freshness.
	inputs?: [...string]
	// Permitted environment variable names or prefixes setup may export to tasks.
	allow_env?: [...string]
	// Repository-relative or shard-scoped path prefixes setup may write context files under.
	owned_paths?: [...string]
}
