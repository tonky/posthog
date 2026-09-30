package replay

// PostHog conventions no repository file records: `tools/hogbox-preview` runs its tests
// inside itself (`uv run`), so `hogbox_preview` is importable from its working directory.
pipeline: analysis: python: module_roots: ["tools/hogbox-preview"]

// What PostHog looks up by string at runtime: Django models by label (and by bare name
// in relation fields of their own app), Celery tasks and Temporal workflows and
// activities by name, management commands by module, and views by URL route (DRF
// routers and Django `path`s; `@action` methods; `reverse` names with DRF's suffixes).
pipeline: analysis: python: registries: [
	{
		name: "models"
		declare: class_name_in: {
			files: ["**/models.py", "**/models/**/*.py"]
			label: ["Meta.app_label", "apps.py:label", "apps.py:name"]
			bare: {
				calls: ["ForeignKey", "OneToOneField", "ManyToManyField"]
				keywords: ["to", "through"]
			}
		}
		use: exclude: ["**/migrations/**"]
	},
	{
		name: "celery_tasks"
		declare: decorator_keyword: {decorators: ["shared_task", "task"], keyword: "name"}
	},
	{
		name: "temporal"
		declare: decorator_keyword: {
			decorators: ["defn"]
			keyword:    "name"
			unnamed: calls: [
				"start_workflow",
				"execute_workflow",
				"start_child_workflow",
				"execute_child_workflow",
				"start_activity",
				"execute_activity",
				"ScheduleActionStartWorkflow",
			]
		}
	},
	{
		name: "commands"
		declare: module_in: files: ["**/management/commands/*.py"]
		use: calls: ["call_command"]
	},
	{
		name: "urls"
		declare: routes: {
			calls: ["register", "path", "re_path"]
			actions: {decorators: ["action"], keyword: "url_path"}
			names: {
				calls: ["reverse"]
				keywords: ["name", "basename"]
				positional: 2
				suffixes: ["-list", "-detail"]
				action_join: "-"
			}
		}
	},
]
