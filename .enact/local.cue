package replay

import "enact.dev/schema"

pipeline: schema.#Pipeline & {
	workflows: {
		local: {
			layout:   "staged"
			services: "on_demand"
			stages: [
				_preflightStage,
				_testStage,
			]
		}
	}
}
