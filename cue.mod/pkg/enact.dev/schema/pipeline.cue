package schema

// The component fields that each declare a one-task job of the same name.
#Slots: ["lint", "fmt", "typecheck", "audit", "build", "pack", "smoke", "migrate", "schema_check", "test"]

// Single job node within the execution DAG.
#Job: {
	name?:   string
	worker?: string
	shards?:     #ShardingSpec
	max_shards?: int & >0
	resources?:  #ResourceSpec
	artifacts?:  #ArtifactSpec
	tasks?: [...#Task]
	// Test target selection for this job. Without one it runs whole; the `test` job
	// falls back to its component's `target_scope` (or `scoping.selector`).
	target_scope?: #TargetScope
	tools?: [...(#Tool | string)]
}

// Artifact capture specification.
#ArtifactSpec: {
	paths: [...string]
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
	name?: string
	labels: [...string]
	cpus:          number
	memory_mb:     int
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
}

// Global CI execution & capacity configuration
#CiConfig: {
	// Available worker / runner types in the CI environment
	workers?: [string]: #WorkerSpec

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

	// Execution and fleet optimization scheduler settings
	scheduler?: #SchedulerSettings

	// Path to test quarantine manifest (e.g. .test_quarantine.json)
	quarantine_file?: string

	// Path to coverage data file (e.g. coverage.json, lcov.info, or .enact/coverage-map.json)
	coverage_file?: string
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

// Repository-wide toolchains CI prepares before running tasks.
#Toolchain: {
	node?: {
		package_manager: "pnpm" | "npm" | "yarn" | "bun"
		install?:        string
		env?: [string]: string
	}
}

// Declarative filesystem scope specification (sparse checkout cone & audit filtering).
#WorkspaceScope: {
	include?: [...string]
	ignore?: [...string]
	include_dependencies?: bool | *true
	// Command printing extra cone paths
	resolver?: #SelectorSpec
	// Commands printing cone paths; `replace` swaps a component's cone (component level only)
	hooks?: #ScopeHooks
}

#ScopeHooks: {
	pre?: [...string] | string
	replace?: string
	post?: [...string] | string
}

// Test target selection for a component: rules map changed files to targets.
#TargetScope: {
	// With no changed files or no resolved targets: run everything, or nothing
	fallback?: #SelectorFallbackMode | *#SelectorFallback.All
	// Target that stands for "the whole component" (e.g. an addon's test tag)
	default_target?: string
	rules?: [...#TargetRule]
	hooks?: #ScopeHooks
}

#TargetRule: {
	id?: string
	match: [...string] | string
	// Built-in impact analyzer for the matching files. `coverage` runs the whole suite
	// when a matching file is missing from the coverage map, or there is no map.
	engine?: "python" | "typescript" | "coverage"
	// Command printing targets for the matching files ({changed_files})
	command?: string
	// "full_component" runs the whole suite when a file matches, whatever the engine;
	// "ignore" says the matching files reach no test (a changed file of the component
	// that no rule matches, other than a doc, runs the whole suite)
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

	// Dependency conventions and Python test selection
	analysis?: #Analysis

	// Dynamic component discovery command (optional)
	components_discovery?: string | [...string]
	componentsDiscovery?: string | [...string]

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

// Language analysis: repository conventions the dependency scanner and test scoper follow.
#Analysis: {
	dependencies?: #DependencyRules
	python?:       #PythonAnalysis
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

// How a registry keys what it holds: exactly one form.
#RegistryDeclare: {
	// Each top-level class of `files`, keyed "<label>.<Class>". `label` lists where a
	// class's label is read, first found wins: "Class.attribute" of a class nested in it
	// ("Meta.app_label"), or "file:attribute", a class attribute in the nearest such file
	// up the tree, its last dotted segment ("apps.py:label", "apps.py:name"). With `bare`,
	// the class name alone is a key too, in files of the same label, as the first
	// positional argument or one of `keywords` of `calls` only.
	class_name_in: {
		files: [...string]
		exclude?: [...string]
		label: [...string]
		bare?: {
			calls: [...string]
			keywords?: [...string]
		}
	}
} | {
	// Each top-level function or class decorated by one of `decorators` (by last name)
	// with a string `keyword`, keyed by it. With `unnamed`, one decorated without it is
	// keyed by its own name, as an argument of `calls` only.
	decorator_keyword: {
		decorators: [...string]
		keyword: string
		unnamed?: calls: [...string]
	}
} | {
	// Each module of `files`, keyed by its file stem.
	module_in: {
		files: [...string]
		exclude?: [...string]
	}
} | {
	// Routes: calls of `calls` (by last name) outside functions whose first argument is
	// a route string and whose second names a repository class or function (through
	// `View.as_view()` or a wrapper), keyed by the route's last literal segment. A
	// URL-shaped string in test code (test files and their support: conftests, helpers
	// under test directories) uses the key of its deepest segment that is one. With
	// `actions`, a handler class's methods decorated by `decorators` route under it by
	// `keyword` (else their name), and a URL whose deepest route segment is an action
	// uses the route before it too. With `names`, the call's string `keywords` or its
	// `positional` argument name the route: keys, also with each of `suffixes`, and
	// with `action_join` "<name><join><method>" per action, used as arguments of
	// `calls` only. `use.calls` doesn't apply.
	routes: {
		calls: [...string]
		actions?: {
			decorators: [...string]
			keyword:    string
		}
		names?: {
			calls: [...string]
			keywords?: [...string]
			positional?: int & >=2
			suffixes?: [...string]
			action_join?: string
		}
	}
}

#ScoperHooks: {
	pre?:      string
	override?: string
	post?:     string
}

// Python test selection: which tests cover a changed file.
#PythonAnalysis: {
	// Files marking a module root; its tests cover changes below it
	module_markers?: [...string] | *["pyproject.toml", "setup.py"]
	// Directories on `sys.path` for every file that no repository file records
	// (repository-relative; `*` matches one segment), e.g. a tool whose tests run inside it.
	// Component roots need no entry: tasks run in them.
	module_roots?: [...string]
	// Namespace packages whose portions are directories (PEP 420, or a package extending
	// its `__path__` at run time): `<module>.<rest>` is `<rest>` under each dir, in order,
	// e.g. {module: "odoo.addons", dirs: ["odoo/addons", "addons"]}.
	namespaces?: [...{
		module: string
		dirs: [...string]
	}]
	// Plugins the runtime installs by manifest: each subdirectory of `namespace`'s portions
	// holding `manifest` (a Python literal dict, or JSON) is one. A test process of plugin P
	// loads P's install set: the `depends` closure of `always` and P, then every plugin whose
	// `auto_install` triggers (`true`: all of its `depends`; a list: those) are installed,
	// to a fixpoint. Declaring it states that each plugin's tests run in their own process
	// installing only that set; a change to what a plugin loads selects the tests of every
	// plugin installing it.
	plugins?: {
		namespace:     string
		manifest:      string
		depends:       string
		auto_install?: string
		// Manifest keys listing files, relative to the plugin, that installing it loads
		data?: [...string]
		// Subpackages the runner imports for every installed plugin: only their
		// import-time code reaches other plugins' tests
		tests?: [...string]
		// Plugins every test process installs
		always?: [...string]
	}
	// Load sites that load something other than what they spell: in `file` (in `function`
	// only, `f` or `Class.method`, when given), computed loads load the plugins of the
	// running test's install set ("plugins": no edge, not open), or these modules (a dotted
	// name with at most one `*`; `[]` for packages outside the repository).
	loads?: [...{
		file:      string
		function?: string
		loads:     "plugins" | [...string]
		reason:    string
	}]
	// Registries the runtime looks things up in by string: a string literal equal to a key
	// (case-insensitively; two adjacent string arguments of a call joined by ".") uses what
	// the key names, where the code holding the string runs. Keys come from one `declare`
	// form; `use` limits where strings count (`calls`: arguments of these calls only, by
	// last name; `exclude`: never in these files).
	registries?: [...{
		name:    =~"^[A-Za-z0-9_-]+$"
		declare: #RegistryDeclare
		use?: {
			calls?: [...string]
			exclude?: [...string]
		}
	}]
	entities?: {
		track_models?:   bool
		track_fields?:   bool
		qualify_fields?: bool
		// Class attributes whose string values name the class's entity (e.g. "__tablename__")
		model_attributes?: [...string]
	}
	// Class-level model inheritance (`_name` / `_inherit` style attributes)
	inheritance?: {
		globs: [...string]
		model_attribute:   string
		inherit_attribute: string
		max_depth?:        int & >0
	}
	// Files searched for references to changed symbols
	references?: globs?: [...string]
	// Test path conventions: {module}, {stem}
	tests?: conventions?: [...string]
	data?: {
		xml?: [...{globs: [...string], extract: [...string]}]
		csv?: [...{globs: [...string], columns: [...string], strip_prefix?: string}]
	}
	symbols_hook?:          #ScoperHooks
	candidates_hook?:       #ScoperHooks
	nodes_hook?:            #ScoperHooks
	rollup_hook?:           #ScoperHooks
	max_methods_per_class?: int & >0
	max_classes_per_file?:  int & >0
	max_methods_per_file?:  int & >0
}
