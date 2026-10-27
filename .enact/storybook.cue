package replay

import "list"

pipeline: components: {
	// The storybook job's runner and footprint instrumentation: run_storybook_tests.sh, the
	// test-runner's per-story load log (enact-loads.ts), the build's chunk map
	// (vite-enact-chunks-plugin.ts) and storybook_footprint.mjs joining the two. They run no
	// tests and storybook depends on them: its harness, left out of its footprints' digests
	// and age, while a change to them still runs storybook whole.
	"storybook_harness": {
		name:       "storybook_harness"
		title:      "Storybook runner and footprint instrumentation"
		technology: "typescript"
		root:       "."
		depends_on: ["js-root", "build_once"]
		watch_paths: [
			"common/storybook/.storybook/enact-loads.ts",
			"common/storybook/.storybook/plugins/vite-enact-chunks-plugin.ts",
			"showcase/scripts/run_storybook_tests.sh",
			"showcase/scripts/storybook_footprint.mjs",
		]
	}
	// ci-storybook.yml's "Build Storybook" and chromium "Visual regression tests": the
	// static Storybook built and every story rendered by @storybook/test-runner in the env's
	// Playwright chromium, capture-only as upstream (run_storybook_tests.sh). Its paths are
	// upstream's `frontend` filter: the frontend's sources (and quill, through `frontend`),
	// the product and MCP UI apps the stories import, and Storybook's own configuration.
	"storybook": {
		name:        "storybook"
		title:       "Storybook visual regression"
		description: "Every story rendered in chromium by @storybook/test-runner, its screenshots captured"
		technology:  "typescript"
		// From the root, as dagster: the stories live across the frontend, the products, quill
		// and the MCP UI apps, and its tests are found under its watch paths' directories.
		root: "."
		depends_on: ["frontend", "storybook_harness"]
		workspace_scope: include: [
			"frontend",
			"products",
			"packages",
			"common",
			"ee/frontend",
			"services/mcp/src/ui-apps",
			"posthog/templates/replay_player_frame",
		]
		workspace_scope: ignore: _productsFrontendBin
		watch_paths: list.Concat([[
			// The stories load HogVM's dist (build_hogvm.sh); frontend watches its sources
			// and package.json, not its build's configs.
			"common/hogvm/typescript/{tsconfig.json,tsconfig.build.json}",
			"frontend/src/**/*.stories.{js,jsx,ts,tsx}",
			"products/**/frontend/**/*.stories.{js,jsx,ts,tsx}",
			"products/*/mcp/apps/**",
			"packages/quill/packages/charts/src/**/*.stories.{js,jsx,ts,tsx}",
			"ee/frontend/**",
			"services/mcp/src/ui-apps/**",
			"playwright.config.ts",
			"patches/jest-junit@16.0.0.patch",
		], _storybookConfig])
		worker: "standard"
		// Upstream: 16 chromium shards on ubuntu-24.04 (4 cores, 16 GB), two jest workers each
		// (test:visual:ci:update's --maxWorkers=2); fewer when fewer stories are selected
		// (`shards` sizes down to the selection; `max_shards` alone would plan the whole suite
		// on 4 while its stories have no recorded durations). The build before them, once; it
		// peaks at 6.3 GB (Vite).
		// "Build Storybook": the static Storybook (with the quill and hogvm dists and the
		// products' manifests it builds first), built once for every shard: CI builds it in a
		// job of its own, cached under its key, and each shard restores it, where each of the
		// 16 shards built it before. run_storybook_tests.sh finds its key current.
		jobs: build: {
			name:      "Build"
			services:  false
			resources: {cpus: 4.0, memory_mb: 8192}
			outputs: {
				paths: [
					"common/storybook/dist",
					"packages/quill/packages/*/dist",
					"common/hogvm/typescript/dist",
					"frontend/.cache/products.hash",
				]
				// What run_storybook_tests.sh's build keys on (build_once.sh), and the builds.
				key: [
					"frontend/**",
					"products/**",
					"common/**",
					"packages/**",
					"ee/frontend/**",
					"services/mcp/src/ui-apps/**",
					"posthog/templates/replay_player_frame/**",
					"package.json",
					"pnpm-lock.yaml",
					"pnpm-workspace.yaml",
					"turbo.json",
					"tsconfig.json",
					"patches/**",
					"showcase/scripts/{run_storybook_tests.sh,build_once.sh,build_quill.sh,build_hogvm.sh,build_products.sh,exclusive.sh}",
				]
			}
			tasks: [{name: "Build Storybook", command: "showcase/scripts/run_storybook_tests.sh --build", timeout: "30m"}]
		}
		// The builds whose outputs are tracked (build:products rewrites products.tsx and
		// productScenes.tsx, as committed on a fresh checkout) run in a task of their own,
		// before the tests' task: what the tests read then changed before they ran, and their
		// footprints land. The tests' task finds them built.
		jobs: test: {
			name:       "Test"
			needs: ["build"]
			// run_storybook_tests.sh records (storybook_footprint.mjs).
			recorder:   "own"
			shards:     16
			// Without the build: 1.8 GB for one story file's 4 stories (Mac).
			resources: {cpus: 2.0, memory_mb: 4096}
			tasks: [
				{name: "Build products", command: "showcase/scripts/build_quill.sh && showcase/scripts/build_hogvm.sh && showcase/scripts/build_products.sh"},
				{name: "Run Tests", command: "showcase/scripts/run_storybook_tests.sh {shard_index} {shard_total} {targets}", timeout: "45m"},
			]
		}
		// The story files .storybook/main.ts collects. A story's own change, or a source it
		// imports, runs the stories reaching it (upstream's module-graph selection);
		// anything else of the component runs every story.
		target_scope: {
			fallback: "all"
			tests: [
				"frontend/src/**/*.stories.{js,jsx,ts,tsx}",
				"products/**/frontend/**/*.stories.{js,jsx,ts,tsx}",
				"products/**/mcp/apps/**/*.stories.{js,jsx,ts,tsx}",
				"services/mcp/src/ui-apps/**/*.stories.{js,jsx,ts,tsx}",
				"packages/quill/packages/charts/src/**/*.stories.{js,jsx,ts,tsx}",
			]
			rules: [{
				match: [
					"frontend/**/*.{ts,tsx,js,jsx,mjs}",
					"products/**/*.{ts,tsx,js,jsx,mjs}",
					"ee/frontend/**/*.{ts,tsx,js,jsx}",
					"services/mcp/src/ui-apps/**/*.{ts,tsx}",
					"packages/quill/**/*.{ts,tsx}",
				]
				engine:      "typescript"
				granularity: "file"
			}, {
				// Visual Review's baselines, and the hogvm package's tests (build_hogvm.sh
				// builds its sources): no story reads them.
				match: [
					"frontend/snapshots.yml",
					"common/hogvm/typescript/src/**/*.test.ts",
					"common/hogvm/typescript/src/**/__tests__/**",
				]
				action: "ignore"
			}]
		}
	}
}
