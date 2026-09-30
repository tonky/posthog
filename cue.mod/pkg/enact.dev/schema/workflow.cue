package schema

// Component reference: direct component struct or string name
#ComponentRef: #Component | string

// Execution scope strategy or explicit list of target components
#WorkflowScope: #WorkflowScopeStrategyMode | [...#ComponentRef]

// Selector matching component jobs by component and/or job name
#TaskSelector: {
	component?: #ComponentRef
	job?:       string
}

// Task filter: every component's job of that name (`pipeline.#jobs.test`), or a selector
#TaskFilter: string | #TaskSelector

// Execution stage: component jobs picked by `select`, then inline `tasks`
#Stage: {
	name: string
	// A `ci.workers` entry name, else a literal runner label.
	runner?: string
	// Stage names this one waits for (static layout)
	needs?: [...string]
	// Inline commands run after the selected jobs (repository checks)
	tasks?: [...#Task]
	// Component jobs to run; empty selects every job
	select?: [...#TaskFilter]
	// The stage CI runs as the sharded test matrix; at most one per workflow
	matrix?: bool
	fail_fast?: bool | *false
	services?:  #ServicePolicyMode
	tools?: [...(#Tool | string)]
}

// Concurrency specification with typed scope and automatic cancellation
#ConcurrencySpec: {
	scope:               #ConcurrencyScopeMode
	cancel_in_progress?: bool | *true
}

// Declarative workflow orchestration defining execution intent (local vs CI)
#Workflow: {
	scope?:  #WorkflowScope
	layout?: #WorkflowLayoutMode
	// Stages in execution order
	stages?: [...#Stage]
	services?:    #ServicePolicyMode
	concurrency?: #ConcurrencySpec
	triggers?:    #Trigger
}
