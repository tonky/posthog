package replay

// Reusable Stage Catalog
_preflightStage: {
	name:      "preflight"
	tasks:     ["lint", "fmt", "codegen", "migrations"]
	fail_fast: true
	services:  "disabled"
}

_testStage: {
	name:      "tests"
	tasks:     ["test", "unit", "integration", "typecheck", "audit"]
	fail_fast: false
	services:  "on_demand"
}
