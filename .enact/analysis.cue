package replay

pipeline: analysis: {
	durations: [".enact/state/pytest/durations-*.json"]
	recorders: {
		"rust_footprint.py":       "3"
		"storybook_footprint.mjs": "1"
		"live_footprint.py":       "3"
	}
	derived: [
		{
			outputs: ["common/hogvm/typescript/dist", "common/hogvm/typescript/dist/**", "common/hogvm/typescript/.turbo", "common/hogvm/typescript/.turbo/**"]
			inputs:  ["common/hogvm/typescript/src/**", "common/hogvm/typescript/package.json", "common/hogvm/typescript/tsconfig.json", "common/hogvm/typescript/tsconfig.build.json"]
			exclude: ["common/hogvm/typescript/src/**/*.test.ts"]
		},
		{
			outputs: ["packages/agent/packages/*/dist", "packages/agent/packages/*/dist/**"]
			inputs:  ["packages/agent/packages/*/src/**", "packages/agent/packages/*/package.json", "packages/agent/packages/*/tsconfig*.json", "packages/agent/packages/*/tsup.config.ts"]
			exclude: ["packages/agent/packages/*/src/**/*.test.ts"]
			mapped:  ["packages/agent/packages/*/src/**"]
		},
		{
			outputs: ["packages/quill/packages/*/dist", "packages/quill/packages/*/dist/**"]
			inputs: [
				"packages/quill/package.json", "packages/quill/tsconfig.json", "packages/quill/postcss.config.cjs",
				"packages/quill/packages/*/src/**", "packages/quill/packages/*/scripts/**",
				"packages/quill/packages/*/package.json", "packages/quill/packages/*/components.json",
				"packages/quill/packages/*/tsconfig*.json", "packages/quill/packages/*/vite.config.ts",
			]
			exclude: ["packages/quill/packages/*/src/**/*.test.ts", "packages/quill/packages/*/src/**/*.test.tsx"]
		},
		{
			outputs: ["services/mcp/shared", "services/mcp/shared/**"]
			inputs: [
				"products/posthog_ai/skills/querying-posthog-data/references/guidelines.md",
				"products/ai_observability/backend/prompts/parser_recipe_examples.yaml",
				"services/mcp/scripts/copy-instructions.ts",
			]
		},
		{
			outputs: ["services/mcp/public/ui-apps", "services/mcp/public/ui-apps/**"]
			inputs: [
				"services/mcp/src/ui-apps/**", "services/mcp/scripts/**", "services/mcp/package.json",
				"services/mcp/vite.ui-apps.config.ts", "products/*/mcp/**",
				"products/product_analytics/frontend/insights/*/shared/**",
				"products/product_analytics/frontend/insights/paths/*Transforms.ts",
				"products/product_analytics/frontend/insights/trends/*/*Transforms.ts",
				"services/mcp/src/tools/exec-names.ts",
				"packages/quill/**",
			]
			exclude: ["**/dist/**", "**/node_modules/**", "**/*.test.{ts,tsx}", "**/*.stories.tsx"]
		},
		{
			outputs: ["common/plugin_transpiler/dist", "common/plugin_transpiler/dist/**", "common/plugin_transpiler/.turbo", "common/plugin_transpiler/.turbo/**"]
			inputs:  ["common/plugin_transpiler/build.mjs", "common/plugin_transpiler/package.json", "common/plugin_transpiler/src/**", "common/plugin_transpiler/tsconfig.json"]
		},
		{
			outputs: ["share/GeoLite2-City.*"]
			inputs:  ["bin/download-mmdb"]
		},
		{
			outputs: ["nodejs/.tmp", "nodejs/.tmp/**"]
			inputs:  ["nodejs/jest.setup-env.ts", "nodejs/tests/assets/GeoLite2-City-Test.mmdb.br"]
		},
		{
			outputs: ["common/replay-headless/dist", "common/replay-headless/dist/**", "common/replay-headless/.turbo", "common/replay-headless/.turbo/**"]
			inputs:  ["common/replay-headless/build.mjs", "common/replay-headless/package.json", "common/replay-headless/src/**", "common/replay-shared/package.json", "common/replay-shared/src/**"]
			exclude: ["common/replay-headless/src/**/*.test.ts", "common/replay-shared/src/**/*.test.ts"]
		},
		{
			outputs: ["rust/replay-anonymizer-node/dist", "rust/replay-anonymizer-node/dist/**", "rust/replay-anonymizer-node/index.node", "rust/replay-anonymizer-node/cargo.log"]
			inputs: [
				"rust/replay-anonymizer-node/Cargo.toml", "rust/replay-anonymizer-node/package.json",
				"rust/replay-anonymizer-node/src/**", "rust/replay-anonymizer-node/tsconfig.json",
				"rust/replay-anonymizer/Cargo.toml", "rust/replay-anonymizer/src/**", "rust/Cargo.lock",
			]
		},
		{
			outputs: ["packages/agent/.turbo", "packages/agent/.turbo/**", "packages/agent/packages/*/.turbo", "packages/agent/packages/*/.turbo/**"]
			inputs:  ["packages/agent/package.json", "packages/agent/turbo.json", "packages/agent/packages/*/package.json"]
		},
		{
			outputs: ["packages/quill/packages/*/.turbo", "packages/quill/packages/*/.turbo/**"]
			inputs:  ["packages/quill/package.json", "packages/quill/packages/*/package.json"]
		},
		{
			outputs: ["frontend/dist", "frontend/dist/**", "frontend/.cache", "frontend/.cache/**", "frontend/tmp", "frontend/tmp/**", "staticfiles", "staticfiles/**"]
			inputs:  ["frontend/package.json", "frontend/build.mjs", "frontend/tsconfig.json"]
		},
		{
			outputs: ["rust/replay-anonymizer-node/.turbo", "rust/replay-anonymizer-node/.turbo/**"]
			inputs:  ["rust/replay-anonymizer-node/package.json", "rust/replay-anonymizer-node/Cargo.toml"]
		},
		{
			outputs: ["rust/ai-research/replay-core-v4-node/dist", "rust/ai-research/replay-core-v4-node/dist/**", "rust/ai-research/replay-core-v4-node/.turbo", "rust/ai-research/replay-core-v4-node/.turbo/**"]
			inputs:  ["rust/ai-research/replay-core-v4-node/package.json", "rust/ai-research/replay-core-v4-node/Cargo.toml", "rust/ai-research/replay-core-v4-node/src/**"]
		},
		{
			outputs: ["common/storybook/dist", "common/storybook/dist/**", "common/storybook/.workers", "common/storybook/.workers/**"]
			inputs:  ["common/storybook/**"]
			exclude: ["common/storybook/dist/**", "common/storybook/.workers", "common/storybook/.workers/**"]
		},
		{
			outputs: ["services/mcp/.wrangler", "services/mcp/.wrangler/**"]
			inputs:  ["services/mcp/package.json", "services/mcp/wrangler.*"]
		},
		{
			outputs: ["rust/common/hogvm/node/index.node", "rust/common/hogvm/node/target", "rust/common/hogvm/node/target/**", "rust/common/hogvm/node/.turbo", "rust/common/hogvm/node/.turbo/**"]
			inputs: [
				"rust/common/hogvm/Cargo.toml", "rust/common/hogvm/src/**",
				"rust/common/hogvm/node/Cargo.toml", "rust/common/hogvm/node/Cargo.lock",
				"rust/common/hogvm/node/build.rs", "rust/common/hogvm/node/package.json",
				"rust/common/hogvm/node/src/**", "rust/Cargo.toml", "rust/Cargo.lock",
			]
		},
		{
			outputs: ["nodejs/dist", "nodejs/dist/**", "nodejs/.turbo", "nodejs/.turbo/**"]
			inputs:  ["nodejs/package.json", "nodejs/tsconfig.json", "nodejs/src/**"]
		},
		{
			outputs: ["playwright/playwright-report/**", "playwright/test-results/**", ".playwright-screenshots/**"]
			inputs:  ["playwright/playwright.config.ts", "playwright/package.json"]
		},
		{
			outputs: [".enact/state/live-bin/**"]
			inputs:  ["rust/Cargo.toml", "rust/Cargo.lock"]
		},
		{
			outputs: [".turbo", ".turbo/**", ".parcel-cache", ".parcel-cache/**"]
			inputs:  ["package.json", "pnpm-lock.yaml", "turbo.json"]
		},
		{
			outputs: [".hypothesis", ".hypothesis/**", "**/.hypothesis", "**/.hypothesis/**", "showcase/scripts/product_pytest.py/.venv", "showcase/scripts/product_pytest.py/.venv/**"]
			inputs:  ["pyproject.toml", "uv.lock"]
		},
		{
			outputs: ["posthog/tasks/test/__emails__", "posthog/tasks/test/__emails__/**", "posthog/ee/tasks/test/__emails__/**", "ee/tasks/test/__emails__/**"]
			inputs:  ["posthog/tasks/test/utils_email_tests.py", "posthog/templates/email/**"]
		},
	]
}
