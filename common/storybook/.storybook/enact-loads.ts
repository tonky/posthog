import type { BrowserContext, Page } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'

/**
 * enact's Storybook footprints, the browser's half: with ENACT_STORYBOOK_LOADS set (a directory;
 * showcase/scripts/run_storybook_tests.sh sets it when enact records footprints), every URL a
 * story file's browser context requests, its pages' and workers', from before the preview's
 * first load on. Each story file gets a fresh context (`prepare`), so what one requested is that
 * file's. After each of its stories one JSON line names the story file (the jest test file) and
 * the URLs so far; showcase/scripts/storybook_footprint.mjs maps them to the repository's files
 * through the build's dist/enact-chunks.json.
 */
const LOADS_DIR = process.env.ENACT_STORYBOOK_LOADS
// On the page itself: jest loads this module once for the environment (`prepare`) and again
// in each test file's registry (`postVisit`), so module state isn't shared between them.
type Recorded = Page & { __enactLoads?: Set<string> }

export function recordLoads(page: Page, browserContext: BrowserContext): void {
    if (!LOADS_DIR) {
        return
    }
    const urls = new Set<string>()
    ;(page as Recorded).__enactLoads = urls
    browserContext.on('request', (request) => {
        urls.add(request.url())
    })
}

export function saveLoads(page: Page, storyId: string): void {
    const urls = LOADS_DIR ? (page as Recorded).__enactLoads : undefined
    if (!LOADS_DIR || !urls) {
        return
    }
    const file = (globalThis as { expect?: { getState?: () => { testPath?: string } } }).expect?.getState?.()?.testPath
    fs.mkdirSync(LOADS_DIR, { recursive: true })
    fs.appendFileSync(
        path.join(LOADS_DIR, `${process.pid}.jsonl`),
        JSON.stringify({ file: file ?? null, story: storyId, urls: [...urls] }) + '\n'
    )
}
