import type { TestRunnerConfig } from '@storybook/test-runner'

import upstream from '../.storybook/test-runner'
import { recordLoads, saveLoads } from '../.storybook/enact-loads'

/**
 * enact's test-runner configuration: upstream's (.storybook/test-runner.ts) as it is, with the
 * URLs each story file's browser context requests recorded (enact-loads.ts, a no-op unless
 * ENACT_STORYBOOK_LOADS is set). Recording starts before upstream's prepare loads the preview.
 */
const config: TestRunnerConfig = {
    ...upstream,
    async prepare(context) {
        recordLoads(context.page, context.browserContext)
        await upstream.prepare?.(context)
    },
    async postVisit(page, context) {
        saveLoads(page, context.id)
        await upstream.postVisit?.(page, context)
    },
}

export default config
