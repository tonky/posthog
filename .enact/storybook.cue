package replay

import "list"

_storybookTestJob: {
	needs:     ["build"]
	recorder:  "own"
	resources: {cpus: 2.0, memory_mb: 4096}
	_args:     string | *""
	tasks: [
		{name: "Build products", command: "showcase/scripts/build_quill.sh && showcase/scripts/build_hogvm.sh && showcase/scripts/build_products.sh"},
		{name: "Run Tests", command: "showcase/scripts/run_storybook_tests.sh \(_args){shard_index} {shard_total} {targets}", timeout: "45m"},
	]
}

pipeline: components: {
	"storybook_harness": _harness & {
		name:       "storybook_harness"
		title:      "Storybook runner and footprint instrumentation"
		technology: "typescript"
		depends_on: ["js-root", "build_once"]
		watch_paths: [
			"common/storybook/.storybook-enact/**",
			"common/storybook/.storybook/enact-loads.ts",
			"common/storybook/.storybook/plugins/vite-enact-chunks-plugin.ts",
			"showcase/scripts/run_storybook_tests.sh",
			"showcase/scripts/storybook_footprint.mjs",
		]
	}
	"storybook": {
		name:        "storybook"
		title:       "Storybook visual regression"
		description: "Every story rendered in chromium by @storybook/test-runner, its screenshots captured"
		technology:  "typescript"
		root:        "."
		depends_on:  ["frontend", "storybook_harness", "vitest_marker"]
		workspace_scope: {
			include: [
				"frontend", "products", "packages", "common", "ee/frontend",
				"services/mcp/src/ui-apps", "posthog/templates/replay_player_frame",
			]
			ignore: _productsFrontendBin
		}
		watch_paths: list.Concat([[
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
		jobs: {
			build: {
				name:      "Build"
				services:  false
				needs:     ["quill:build"]
				resources: {cpus: 4.0, memory_mb: 8192}
				outputs: {
					paths: [
						"common/storybook/dist",
						"common/hogvm/typescript/dist", "frontend/.cache/products.hash",
					]
					key: [
						"frontend/**", "products/**", "common/**", "packages/**", "ee/frontend/**",
						"services/mcp/src/ui-apps/**", "posthog/templates/replay_player_frame/**",
						"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "turbo.json",
						"tsconfig.json", "patches/**",
						"showcase/scripts/{run_storybook_tests.sh,build_once.sh,build_quill.sh,build_hogvm.sh,build_products.sh,exclusive.sh}",
					]
				}
				tasks: [{name: "Build Storybook", command: "showcase/scripts/run_storybook_tests.sh --build", timeout: "30m"}]
			}
			test:   _storybookTestJob & {name: "Test", shards: 16}
			webkit: _storybookTestJob & {name: "WebKit", shards: 4, _args: "--browser webkit "}
		}
		target_scope: {
			fallback: "all"
			tests: [
				"frontend/src/**/*.stories.{js,jsx,ts,tsx}",
				"products/**/frontend/**/*.stories.{js,jsx,ts,tsx}",
				"products/**/mcp/apps/**/*.stories.{js,jsx,ts,tsx}",
				"services/mcp/src/ui-apps/**/*.stories.{js,jsx,ts,tsx}",
				"packages/quill/packages/charts/src/**/*.stories.{js,jsx,ts,tsx}",
			]
			rules: [
				{
					match: [
						"frontend/**/*.{ts,tsx,js,jsx,mjs}", "products/**/*.{ts,tsx,js,jsx,mjs}",
						"ee/frontend/**/*.{ts,tsx,js,jsx}", "services/mcp/src/ui-apps/**/*.{ts,tsx}",
						"packages/quill/**/*.{ts,tsx}",
					]
					engine:      "typescript"
					granularity: "file"
				},
				{
					match:  ["frontend/snapshots.yml", "common/hogvm/typescript/src/**/*.test.ts", "common/hogvm/typescript/src/**/__tests__/**"]
					action: "ignore"
				},
			]
		}
	}
}
