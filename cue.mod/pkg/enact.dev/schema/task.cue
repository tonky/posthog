package schema

// Specification for a task execution node (lint, fmt, typecheck, audit, test)
#TaskSpec: {
	phase?:   #TaskPhaseMode
	command:  string
	fix?:     string                  // In-place auto-fix (e.g. "ruff check --fix", "cargo fmt")
	matcher?: #ProblemMatcherMode     // Automatically injects GHA problem matcher
	env?:     [string]: string
	timeout?: int                     // Timeout in seconds
}

// Code generation and uncommitted drift verification specification
#CodegenSpec: {
	command:          string
	checkUncommitted: bool | *true      // Enforces `git diff --exit-code <outputs>`
	watchPaths?:      [...string]       // Source paths that invalidate this codegen
	outputs?:         [...string]       // Generated paths to check
}

// Architectural contract and breaking change verification specification
#ContractSpec: {
	command:      string               // e.g. "buf breaking proto/"
	againstRef:   string | *"origin/master"
	failOnBreak:  bool | *true
}

// Database schema migration verification specification
#MigrationSpec: {
	engine:          #MigrationEngineMode // e.g. #MigrationEngine.Django
	migrationsDir:   string
	goldenDump?:     string               // e.g. "showcase/data/schema-latest.sql.gz"
	checkDeletions:  bool | *true         // Flags removed or renamed migrations
	targetDatabases?: [...string]          // Target databases to verify
}

// Declarative test target selector specification
#SelectorSpec: {
	// Command that accepts changed files and outputs resolved test targets
	command:   string                   // e.g. "python tools/snob.py {changed_files}" or "go list -test {changed_files}"
	format?:   "lines" | "json" | "space" | *"lines"
	fallback?: "all" | "none" | *"all"  // If selector fails or cannot determine
	timeout?:  int | *10               // Max seconds to compute selection
}

// Multi-level test and blast radius scoping specification
#ScopingRules: {
	selector?:         #ScopingSelectorMode | #SelectorSpec | string // e.g. #ScopingSelector.PythonSnob or custom selector
	barrels?:          [...string]          // High-fanout barrel files (e.g. ["src/types.ts"])
	universalSymbols?: [...string]          // Symbols forcing full blast-radius execution
	domainRoots?:      [...string]          // Domain boundary roots preventing global graph traversal
	serviceMarkers?:   [...string]          // Regex patterns in tests requiring running microservices
	fullRunPatterns?:  [...string]          // Global config files triggering full test execution
}

