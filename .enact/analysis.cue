package replay

// Where PostHog's per-test timings live: upstream's pytest-split durations as per-file totals
// (durations-upstream.json, showcase/scripts/fetch_test_durations.sh), and what each test cost
// its shard as the overlay's pytest plugin records it: setup, call and teardown, and a share of
// its pytest process's start-up, one process per product
// (showcase/pytest_plugins/pytest_timings.py).
pipeline: analysis: durations: [".enact/state/pytest/durations-*.json"]

// Git-ignored files the traced tests read, and what writes them: a change to an input
// reaches the tests that read the output.
pipeline: analysis: derived: [{
	// `pnpm build` (parcel, and src/cli.js copied over).
	outputs: ["common/hogvm/typescript/dist/**"]
	inputs: [
		"common/hogvm/typescript/src/**",
		"common/hogvm/typescript/package.json",
		"common/hogvm/typescript/tsconfig.json",
		"common/hogvm/typescript/tsconfig.build.json",
	]
	exclude: ["common/hogvm/typescript/src/**/*.test.ts"]
}, {
	// packages/agent's package builds (tsup, tsc), which the other packages' tests import.
	outputs: ["packages/agent/packages/*/dist/**"]
	inputs: [
		"packages/agent/packages/*/src/**",
		"packages/agent/packages/*/package.json",
		"packages/agent/packages/*/tsconfig*.json",
		"packages/agent/packages/*/tsup.config.ts",
	]
	exclude: ["packages/agent/packages/*/src/**/*.test.ts"]
	// Compiled function by function with source maps (tsup's esbuild, tsc): a body edit of
	// a package's source reaches a test whose dist reads all map into sources only when it
	// ran an edited function (enact-node credits them).
	mapped: ["packages/agent/packages/*/src/**"]
}, {
	// quill's package builds (showcase/scripts/build_quill.sh: vite, tokens' and quill's CSS
	// scripts), which storybook's stories and the frontend import. Declared, a footprint
	// holding them digests their sources, so a host without the build reads it as fresh.
	outputs: ["packages/quill/packages/*/dist/**"]
	inputs: [
		"packages/quill/package.json",
		"packages/quill/tsconfig.json",
		"packages/quill/postcss.config.cjs",
		"packages/quill/packages/*/src/**",
		"packages/quill/packages/*/scripts/**",
		"packages/quill/packages/*/package.json",
		"packages/quill/packages/*/components.json",
		"packages/quill/packages/*/tsconfig*.json",
		"packages/quill/packages/*/vite.config.ts",
	]
	exclude: ["packages/quill/packages/*/src/**/*.test.ts", "packages/quill/packages/*/src/**/*.test.tsx"]
}, {
	// services/mcp's copy-instructions.ts, which each mcp test job's build runs: the shared
	// prompts its tools import, copied in.
	outputs: ["services/mcp/shared/**"]
	inputs: [
		"products/posthog_ai/skills/querying-posthog-data/references/guidelines.md",
		"products/ai_observability/backend/prompts/parser_recipe_examples.yaml",
		"services/mcp/scripts/copy-instructions.ts",
	]
}, {
	// The MCP UI apps' bundles (`pnpm run build:ui-apps`, build_mcp_ui_apps.sh, or the
	// integration suite's global setup when missing). vite.ui-apps.config.ts's `products`
	// alias reaches any product's sources: the apps import product_analytics' chart
	// transforms (FunnelVisualizer, TrendsVisualizer), which only these globs hold of the
	// product frontends (tests/overlay/mcp_integration.rs follows the apps' imports). No
	// alias reaches frontend/src (`~`, `lib`, `scenes`): what the transforms take from it is
	// types, which the build erases, so a frontend edit reaches only its own readers.
	outputs: ["services/mcp/public/ui-apps/**"]
	inputs: [
		"services/mcp/src/ui-apps/**",
		"services/mcp/scripts/**",
		"services/mcp/package.json",
		"services/mcp/vite.ui-apps.config.ts",
		"products/*/mcp/**",
		"products/product_analytics/frontend/insights/*/shared/**",
		"products/product_analytics/frontend/insights/trends/*/*Transforms.ts",
		"packages/quill/**",
	]
	exclude: ["**/dist/**", "**/node_modules/**", "**/*.test.{ts,tsx}", "**/*.stories.tsx"]
}, {
	// The site apps' transpiler (`tsc -b && node build.mjs`, esbuild), which products/cdp's
	// transpile() runs as `node common/plugin_transpiler/dist/index.js` (core's test_plugin).
	outputs: ["common/plugin_transpiler/dist/**"]
	inputs: [
		"common/plugin_transpiler/build.mjs",
		"common/plugin_transpiler/package.json",
		"common/plugin_transpiler/src/**",
		"common/plugin_transpiler/tsconfig.json",
	]
}, {
	// The GeoIP database bin/download-mmdb installs: the latest GeoLite2 build from an
	// unpinned CDN, fetched only when share/ lacks it, so no repository file pins its bytes
	// (they differ by host and day). The installer is the one file that decides what a fresh
	// checkout reads (its URL, its decompression), so a reader's footprint stands for it,
	// not for the database. It is geoip's, harness to every suite whose runner installs the
	// database: its edit runs the readers and ages none of them.
	outputs: ["share/GeoLite2-City.*"]
	inputs: ["bin/download-mmdb"]
}, {
	// The frontend's page templates Django renders: empty stubs the test runner writes, as
	// ci-backend.yml does, where no frontend build is present.
	outputs: ["frontend/dist/*.html"]
	inputs: ["showcase/scripts/run_sharded_pytest.sh"]
}, {
	// The plugin server's jest setup (jest.setup-env.ts): each worker's GeoIP test database,
	// decompressed from the fixture as the run starts.
	outputs: ["nodejs/.tmp/**"]
	inputs: ["nodejs/jest.setup-env.ts", "nodejs/tests/assets/GeoLite2-City-Test.mmdb.br"]
}, {
	// @posthog/replay-headless's build (build.mjs, esbuild), which the plugin server's
	// workspace build runs and its rasterizer imports (./protocol) and serves (the player).
	outputs: ["common/replay-headless/dist/**"]
	inputs: [
		"common/replay-headless/build.mjs",
		"common/replay-headless/package.json",
		"common/replay-headless/src/**",
		"common/replay-shared/package.json",
		"common/replay-shared/src/**",
	]
	exclude: ["common/replay-headless/src/**/*.test.ts", "common/replay-shared/src/**/*.test.ts"]
}, {
	// @posthog/replay-anonymizer's build (cargo, the library copied to index.node, tsc), which
	// the plugin server's workspace build runs and its session replay ingestion loads.
	outputs: [
		"rust/replay-anonymizer-node/dist/**",
		"rust/replay-anonymizer-node/index.node",
		"rust/replay-anonymizer-node/cargo.log",
	]
	inputs: [
		"rust/replay-anonymizer-node/Cargo.toml",
		"rust/replay-anonymizer-node/package.json",
		"rust/replay-anonymizer-node/src/**",
		"rust/replay-anonymizer-node/tsconfig.json",
		"rust/replay-anonymizer/Cargo.toml",
		"rust/replay-anonymizer/src/**",
		"rust/Cargo.lock",
	]
}]

// The footprint recorder's version (enact_footprint.py writes `"recorder"`): bumping it
// re-records only the footprints it wrote. 5: Hypothesis's constant mining unrecorded (it
// left every footprint of its process function-blind), lost monitoring makes targets opaque.
pipeline: analysis: recorders: "enact_footprint.py": "6"

// run_rust_tests.sh's recorder (rust_footprint.py writes `"recorder"`): what a test binary
// read running plus what it was built from. 2: no build script's generated sources (the
// target dir's paths are a host's build, not the test's input).
pipeline: analysis: recorders: "rust_footprint.py": "3"

// storybook_footprint.mjs: the stories' (the build's outputs their browser fetched);
// live_footprint.py: the e2e and MCP integration specs' (the test runner's reads, the live
// app's, restarted per spec, and the frontend build's outputs it served). 2: each spec holds
// what the stack's Rust services were built from (live_posthog.sh, rust_footprint.py).
pipeline: analysis: recorders: "storybook_footprint.mjs": "1"
pipeline: analysis: recorders: "live_footprint.py":       "3"
