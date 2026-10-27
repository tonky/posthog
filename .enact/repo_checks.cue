package replay

// Upstream's light repository checks: shellcheck.yml, container-images-ci.yml's
// Dockerfile lint, ci-agent-skills.yml and ci-duplication.yml.
pipeline: components: {
	// shellcheck.yml: shellcheck over the scripts it names, then their tests, then the two
	// repository-wide path checks (Windows-safe paths, AGENTS.md/CLAUDE.md symlinks).
	// Upstream runs it on every PR; here a change to one of its scripts selects it.
	"shellcheck": {
		name:  "shellcheck"
		title: "Shell scripts & repository path checks"
		// No package ecosystem: no pnpm or uv install before its 30 s of checks.
		technology: "shell"
		root:       "."
		depends_on: ["root"]
		watch_paths: [
			"bin/deploy-hobby",
			".github/scripts/*.sh",
			".github/scripts/desktop/*.sh",
			// Under the pipeline-wide `.agents/**`, `**/.claude/**` and `**/*.md` ignores:
			// named one by one, they stay owned by shellcheck without triggering code suites.
			".agents/skills/triaging-merge-queue-failures/scripts/mq-queue-state.sh",
			".agents/skills/triaging-merge-queue-failures/scripts/mq-queue-state.test.sh",
			".agents/skills/triaging-merge-queue-failures/scripts/mq-triage-marker.sh",
			".claude/settings.json",
			for d in _agentDocDirs {"\(d)AGENTS.md"},
			for d in _agentDocDirs {"\(d)CLAUDE.md"},
		]
		// The workflow's steps, one task each, in its order (the `[ -f … ] || exit 0` guards
		// are upstream's, for PRs from before a script existed).
		jobs: lint: {
			direct:   true
			services: false
			resources: {cpus: 1.0, memory_mb: 512}
			tasks: [{
				name:    "Check secrets scripts"
				command: "cd bin && shellcheck deploy-hobby"
			}, {
				name:    "Check Windows-compatible repository paths"
				command: "shellcheck .github/scripts/check-windows-paths.sh .github/scripts/check-windows-paths.test.sh && .github/scripts/check-windows-paths.test.sh && .github/scripts/check-windows-paths.sh"
			}, {
				name:    "Check desktop backend coupling script"
				command: "shellcheck .github/scripts/desktop/*.sh && .github/scripts/desktop/check-pr-backend-coupling.test.sh"
			}, {
				name:    "Check product JUnit preparation script"
				command: "shellcheck .github/scripts/prepare-product-junit-for-trunk.sh .github/scripts/prepare-product-junit-for-trunk.test.sh && bash .github/scripts/prepare-product-junit-for-trunk.test.sh"
			}, {
				name:    "Check Trunk ownership map script"
				command: "[ -f .github/scripts/trunk-codeowners.test.sh ] || exit 0; shellcheck .github/scripts/trunk-codeowners.sh .github/scripts/trunk-codeowners.test.sh && bash .github/scripts/trunk-codeowners.test.sh"
			}, {
				name:    "Check commit-time warning scripts"
				command: "[ -f .github/scripts/check-commit-warnings.test.sh ] || exit 0; shellcheck .github/scripts/check-claude-hooks.sh .github/scripts/check-quill-agents-md.sh .github/scripts/check-comment-density.sh .github/scripts/check-commit-warnings.test.sh && .github/scripts/check-commit-warnings.test.sh"
			}, {
				name:    "Check merge queue triage helpers"
				command: "d=.agents/skills/triaging-merge-queue-failures/scripts; [ -f \"$d/mq-queue-state.test.sh\" ] || exit 0; shellcheck \"$d/mq-queue-state.sh\" \"$d/mq-queue-state.test.sh\" \"$d/mq-triage-marker.sh\" && bash \"$d/mq-queue-state.test.sh\""
			}, {
				name:    "Check AGENTS.md / CLAUDE.md symlinks"
				command: "shellcheck .github/scripts/check-agents-md-symlinks.sh && .github/scripts/check-agents-md-symlinks.sh"
			}]
		}
	}
	// container-images-ci.yml's "Lint changed Dockerfiles": hadolint over the added and
	// modified Dockerfiles (its paths filter's globs), with the action's defaults
	// (showcase/scripts/hadolint.sh). The image build it gates needs Docker: not modeled.
	"dockerfiles": {
		name:       "dockerfiles"
		title:      "Dockerfiles"
		technology: "docker"
		root:       "."
		depends_on: ["root"]
		watch_paths: [
			for g in _dockerfiles {g},
			"showcase/scripts/hadolint.sh",
		]
		jobs: lint: {
			direct:   true
			services: false
			resources: {cpus: 1.0, memory_mb: 512}
			tasks: [{
				command: "./showcase/scripts/hadolint.sh {changed_files}"
				filter: include: _dockerfiles
			}]
		}
	}
	// ci-agent-skills.yml's "Check agent skills": validates product and project skill sources
	// (`hogli lint:skills`: `python -m products.posthog_ai.scripts.build_skills --lint`).
	"agent_skills": {
		name:       "agent_skills"
		title:      "Agent skills"
		technology: "python"
		root:       "."
		depends_on: ["py-root"]
		workspace_scope: include: ["products", "services/mcp/schema"]
		watch_paths: [
			"products/*/skills/**",
			"products/*/backend/max_tools.py",
			"products/posthog_ai/*",
			"products/posthog_ai/{backend,dags,eval_harness,evals,mcp,scripts,skills}/**",
			"services/mcp/schema/**",
			// In upstream's filter (the glob above), but Markdown is ignored pipeline-wide and
			// only a literal watch outranks an ignore. The lint reads none of it
			// (tool_references.py reads the two tool-definition files): upstream's trigger.
			"services/mcp/schema/exec-command-reference.md",
		]
		jobs: lint: {
			direct:    true
			services:  false
			resources: {cpus: 1.0, memory_mb: 1024}
			tasks: [{
				command: "uv run --no-sync python -m products.posthog_ai.scripts.build_skills --lint"
			}]
		}
	}
	// ci-duplication.yml's "Duplication lint": jscpd over this tree and a worktree of the
	// baseline (`bin/lint_duplication.py`). Upstream runs it on every Python/TS PR; here a
	// change to its script, limits or report helper selects it.
	"duplication": {
		name:       "duplication"
		title:      "Duplication lint"
		technology: "shell"
		root:       "."
		depends_on: ["root"]
		// jscpd scans the whole tree's Python and TypeScript: the directories holding them
		// (rust/'s 18 such files left out of a large checkout).
		workspace_scope: include: [
			"bin", "common", "docs", "ee", "frontend", "livestream", "nodejs", "packages",
			"playwright", "posthog", "products", "services", "tools", ".semgrep",
		]
		watch_paths: [
			"bin/lint_duplication.py",
			"bin/lint-duplication.limits.json",
			".github/scripts/post-duplication-section.mjs",
		]
		// Upstream runs it in a workflow of its own on depot-ubuntu-24.04 (2c/8G), beside the
		// other checks. Its peak (7.8 GB on the Mac) needs a worker pin, which only the matrix
		// stage honours (preflight runs every job on its one runner), so the job has a name
		// of its own: a job two stages select runs in both.
		jobs: jscpd: {
			direct:    true
			services:  false
			worker:    "standard"
			resources: {cpus: 2.0, memory_mb: 8192}
			tasks: [{
				command: "python3 bin/lint_duplication.py --base HEAD"
			}]
		}
	}
}

_dockerfiles: ["**/Dockerfile", "**/*.Dockerfile", "**/Dockerfile.*"]

// Directories holding tracked AGENTS.md / CLAUDE.md pairs checked by
// .github/scripts/check-agents-md-symlinks.sh and .github/scripts/check-quill-agents-md.sh.
_agentDocDirs: [
	"",
	"common/",
	"ee/hogai/eval/",
	"frontend/src/",
	"frontend/src/layout/scenes/",
	"frontend/src/scenes/max/",
	"packages/quill/",
	"packages/quill/packages/blocks/",
	"packages/quill/packages/charts/",
	"packages/quill/packages/components/",
	"packages/quill/packages/primitives/",
	"packages/quill/packages/tokens/",
	"posthog/clickhouse/client/",
	"posthog/clickhouse/migrations/",
	"posthog/egress/",
	"posthog/hogql/database/schema/",
	"posthog/ingress/",
	"posthog/temporal/",
	"posthog/temporal/data_modeling/",
	"posthog/test/",
	"products/ai_observability/",
	"products/ai_observability/fixtures/sample_traces/",
	"products/alerts/",
	"products/autoresearch/",
	"products/autoresearch/backend/dataset/",
	"products/autoresearch/backend/evaluation/",
	"products/autoresearch/backend/inference/",
	"products/autoresearch/backend/management/",
	"products/autoresearch/backend/presentation/",
	"products/autoresearch/backend/temporal/",
	"products/autoresearch/backend/training/",
	"products/autoresearch/frontend/",
	"products/autoresearch/mcp/",
	"products/customer_analytics/backend/",
	"products/customer_analytics/frontend/components/Accounts/",
	"products/dashboards/",
	"products/desktop/",
	"products/desktop/packages/ui/src/features/browser-tabs/",
	"products/desktop/packages/ui/src/features/canvas/",
	"products/desktop/packages/ui/src/features/inbox/",
	"products/engineering_analytics/",
	"products/engineering_analytics/frontend/",
	"products/posthog_ai/eval_harness/harness/",
	"products/posthog_ai/evals/",
	"products/posthog_ai/frontend/",
	"products/product_analytics/",
	"products/signals/backend/emission/",
	"products/signals/backend/management/",
	"products/signals/backend/report_generation/",
	"products/signals/backend/scout_harness/",
	"products/signals/dags/inbox_ranking/",
	"products/signals/eval/",
	"products/signals/skills/",
	"products/stamphog/",
	"products/support/scripts/",
	"proto/",
	"rust/",
	"rust/personhog-replica/",
	"rust/personhog-router/",
	"services/mcp/",
	"tools/hogli/",
]

