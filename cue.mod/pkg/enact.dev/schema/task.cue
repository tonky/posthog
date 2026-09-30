package schema

// Target file matching and empty set evaluation filter
#FileFilter: {
	include: [...string]
	exclude?: [...string]
	on_empty: *#EmptyPolicy.Skip | #EmptyPolicyMode
}

// One command a job runs
#Task: {
	name?: string
	// e.g. "python tools/snob.py {changed_files}" or "go list -test {changed_files}"
	command: string
	shell?:  #ShellMode
	env?: [string]: string
	// Variables removed from the task's environment, e.g. the injected service
	// connection variables for a task that runs against its own throwaway database.
	unset_env?: [...string]
	// e.g. "10m"
	timeout?: #Duration
	filter?:  #FileFilter
	caches?: [...#Cache]
}

// Declarative test target selector specification
#SelectorSpec: {
	// Command that accepts changed files and outputs resolved test targets
	command:   string
	fallback?: #SelectorFallbackMode | *#SelectorFallback.All
	timeout?:  int | *10
	// "file" collapses path::Class::test targets to their file so shards run whole
	// files in their own order (pytest-split parity); "item" keeps them as selected.
	granularity?: #TargetGranularityMode | *#TargetGranularity.Item
	// Drop matrix entries whose selector yields no targets
	prefilter_matrix?: bool | *true
	// Size shards to the selected targets
	adaptive_shards?: bool | *true
}

// Multi-level test and blast radius scoping specification
#ScopingRules: {
	// e.g. #ScopingSelector.PythonSnob or custom selector
	selector?: #ScopingSelectorMode | #SelectorSpec | string
	// High-fanout barrel files (e.g. ["src/types.ts"])
	barrels?: [...string]
	// Symbols forcing full blast-radius execution
	universal_symbols?: [...string]
	// Domain boundary roots preventing global graph traversal
	domain_roots?: [...string]
	// Regex patterns in tests requiring running microservices
	service_markers?: [...string]
	// Global config files triggering full test execution
	full_run_patterns?: [...string]
}
