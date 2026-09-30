package replay

let J = pipeline.#jobs

// Reusable Stage Catalog
_preflightStage: {
	name: "preflight"
	select: [J.lint, J.fmt, J.migrate, J.schema_check]
	fail_fast: true
	services:  "disabled"
}

_testStage: {
	name:   "tests"
	matrix: true
	select: [J.test, J.typecheck, J.audit, J.build]
	fail_fast: false
	services:  "on_demand"
}
