package replay

// Upstream's light repository checks: shellcheck.yml, container-images-ci.yml, ci-agent-skills.yml, ci-duplication.yml.
pipeline: components: {
	"shellcheck": {
		name:       "shellcheck"
		title:      "Shell scripts & repository path checks"
		technology: "shell"
		root:       "."
		depends_on: ["root"]
		watch_paths: [
			"bin/deploy-hobby",
			".github/scripts/*.sh",
			".github/scripts/desktop/*.sh",
			".agents/skills/triaging-merge-queue-failures/scripts/mq-queue-state.sh",
			".agents/skills/triaging-merge-queue-failures/scripts/mq-queue-state.test.sh",
			".agents/skills/triaging-merge-queue-failures/scripts/mq-triage-marker.sh",
			".claude/settings.json",
			for d in _agentDocDirs {"\(d)AGENTS.md"},
			for d in _agentDocDirs {"\(d)CLAUDE.md"},
		]
		jobs: lint: {
			direct:    true
			services:  false
			resources: {cpus: 1.0, memory_mb: 512}
			tasks: [
				{name: "Check secrets scripts", command: "cd bin && shellcheck deploy-hobby"},
				{name: "Check Windows-compatible repository paths", command: "shellcheck .github/scripts/check-windows-paths.sh .github/scripts/check-windows-paths.test.sh && .github/scripts/check-windows-paths.test.sh && .github/scripts/check-windows-paths.sh"},
				{name: "Check desktop backend coupling script", command: "shellcheck .github/scripts/desktop/*.sh && .github/scripts/desktop/check-pr-backend-coupling.test.sh"},
				{name: "Check product JUnit preparation script", command: "shellcheck .github/scripts/prepare-product-junit-for-trunk.sh .github/scripts/prepare-product-junit-for-trunk.test.sh && bash .github/scripts/prepare-product-junit-for-trunk.test.sh"},
				{name: "Check Trunk ownership map script", command: "[ -f .github/scripts/trunk-codeowners.test.sh ] || exit 0; shellcheck .github/scripts/trunk-codeowners.sh .github/scripts/trunk-codeowners.test.sh && bash .github/scripts/trunk-codeowners.test.sh"},
				{name: "Check commit-time warning scripts", command: "[ -f .github/scripts/check-commit-warnings.test.sh ] || exit 0; shellcheck .github/scripts/check-claude-hooks.sh .github/scripts/check-quill-agents-md.sh .github/scripts/check-comment-density.sh .github/scripts/check-commit-warnings.test.sh && .github/scripts/check-commit-warnings.test.sh"},
				{name: "Check merge queue triage helpers", command: "d=.agents/skills/triaging-merge-queue-failures/scripts; [ -f \"$d/mq-queue-state.test.sh\" ] || exit 0; shellcheck \"$d/mq-queue-state.sh\" \"$d/mq-queue-state.test.sh\" \"$d/mq-triage-marker.sh\" && bash \"$d/mq-queue-state.test.sh\""},
				{name: "Check AGENTS.md / CLAUDE.md symlinks", command: "shellcheck .github/scripts/check-agents-md-symlinks.sh && .github/scripts/check-agents-md-symlinks.sh"},
			]
		}
	}
	"dockerfiles": {
		name:        "dockerfiles"
		title:       "Dockerfiles"
		technology:  "docker"
		root:        "."
		depends_on:  ["root"]
		watch_paths: [for g in _dockerfiles {g}, "showcase/scripts/hadolint.sh"]
		resources:   {cpus: 1.0, memory_mb: 512}
		lint: {
			command: "./showcase/scripts/hadolint.sh {changed_files}"
			filter:  include: _dockerfiles
		}
	}
	"agent_skills": {
		name:            "agent_skills"
		title:           "Agent skills"
		technology:      "python"
		root:            "."
		depends_on:      ["py-root"]
		workspace_scope: include: ["products", "services/mcp/schema"]
		watch_paths: [
			"products/*/skills/**",
			"products/*/backend/max_tools.py",
			"products/posthog_ai/*",
			"products/posthog_ai/{backend,dags,eval_harness,evals,mcp,scripts,skills}/**",
			"services/mcp/schema/**",
			"services/mcp/schema/exec-command-reference.md",
		]
		resources: {cpus: 1.0, memory_mb: 1024}
		lint:      "uv run --no-sync python -m products.posthog_ai.scripts.build_skills --lint"
	}
	"duplication": {
		name:       "duplication"
		title:      "Duplication lint"
		technology: "shell"
		root:       "."
		depends_on: ["root"]
		workspace_scope: include: [
			"bin", "common", "docs", "ee", "frontend", "livestream", "nodejs", "packages",
			"playwright", "posthog", "products", "services", "tools", ".semgrep",
		]
		watch_paths: [
			"bin/lint_duplication.py",
			"bin/lint-duplication.limits.json",
			".github/scripts/post-duplication-section.mjs",
		]
		jobs: jscpd: {
			direct:    true
			services:  false
			worker: "standard"
			// jscpd peaks at ~7.5 GB: an 8 GB runner's host guard stops it (upstream's
			// depot-ubuntu-24.04 has 8 GB to itself); 11 GB lands it on a size with headroom.
			resources: {cpus: 2.0, memory_mb: 11264}
			tasks: [{command: "python3 bin/lint_duplication.py --base HEAD"}]
		}
	}
}

_dockerfiles: ["Dockerfile", "Dockerfile.*", "{livestream,products,rust,services}/**/Dockerfile", "{livestream,products,rust,services}/**/*.Dockerfile", "{livestream,products,rust,services}/**/Dockerfile.*"]

_agentDocDirs: [
	"", "common/", "ee/hogai/eval/", "frontend/src/", "frontend/src/layout/scenes/",
	"frontend/src/scenes/max/", "packages/quill/", "packages/quill/packages/blocks/",
	"packages/quill/packages/charts/", "packages/quill/packages/components/",
	"packages/quill/packages/primitives/", "packages/quill/packages/tokens/",
	"posthog/clickhouse/client/", "posthog/clickhouse/migrations/", "posthog/egress/",
	"posthog/hogql/database/schema/", "posthog/ingress/", "posthog/temporal/",
	"posthog/temporal/data_modeling/", "posthog/test/", "products/ai_observability/",
	"products/ai_observability/fixtures/sample_traces/", "products/alerts/",
	"products/autoresearch/", "products/autoresearch/backend/dataset/",
	"products/autoresearch/backend/evaluation/", "products/autoresearch/backend/inference/",
	"products/autoresearch/backend/management/", "products/autoresearch/backend/presentation/",
	"products/autoresearch/backend/temporal/", "products/autoresearch/backend/training/",
	"products/autoresearch/frontend/", "products/autoresearch/mcp/",
	"products/customer_analytics/backend/", "products/customer_analytics/frontend/components/Accounts/",
	"products/dashboards/", "products/desktop/", "products/desktop/packages/ui/src/features/browser-tabs/",
	"products/desktop/packages/ui/src/features/canvas/", "products/desktop/packages/ui/src/features/inbox/",
	"products/engineering_analytics/", "products/engineering_analytics/frontend/",
	"products/posthog_ai/eval_harness/harness/", "products/posthog_ai/evals/",
	"products/posthog_ai/frontend/", "products/product_analytics/",
	"products/signals/backend/emission/", "products/signals/backend/management/",
	"products/signals/backend/report_generation/", "products/signals/backend/scout_harness/",
	"products/signals/dags/inbox_ranking/", "products/signals/eval/", "products/signals/skills/",
	"products/stamphog/", "products/support/scripts/", "proto/", "rust/",
	"rust/personhog-replica/", "rust/personhog-router/", "services/mcp/", "tools/hogli/",
]
