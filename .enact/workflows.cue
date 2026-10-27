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
	select: [J.test, J.test_typescript, J.test_hono, J.test_ignored, J.rust_ingestion_e2e, J.typecheck, J.audit, J.build, J.jscpd]
	fail_fast: false
	services:  "on_demand"
}
