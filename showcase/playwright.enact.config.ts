import path from 'node:path'
import { defineConfig } from '@playwright/test'
import upstreamConfig from '../playwright/playwright.config'

// Upstream sets `testDir: '..'` (the repo root) so Playwright walks every top-level
// directory during test discovery — including `.enve/instances/`, where live ClickHouse
// background merges rapidly create/unlink `tmp_part_*` directories and trigger `ENOENT`.
// Scoped per-project `testDir`s discover the exact same two spec roots without ever
// walking the repo root or `.enve/instances/`.
const playwrightDir = path.resolve(__dirname, '../playwright')
const productsDir = path.resolve(__dirname, '../products')
const baseProject = upstreamConfig.projects?.[0] ?? { name: 'chromium' }

function resolveReporterPath(entry: unknown): unknown {
    if (typeof entry === 'string' && (entry.startsWith('./') || entry.startsWith('../'))) {
        return path.resolve(playwrightDir, entry)
    }
    if (
        Array.isArray(entry) &&
        typeof entry[0] === 'string' &&
        (entry[0].startsWith('./') || entry[0].startsWith('../'))
    ) {
        return [path.resolve(playwrightDir, entry[0]), ...entry.slice(1)]
    }
    return entry
}

const reporter = Array.isArray(upstreamConfig.reporter)
    ? upstreamConfig.reporter.map(resolveReporterPath)
    : resolveReporterPath(upstreamConfig.reporter)

const snapshotDir =
    typeof upstreamConfig.snapshotDir === 'string' && !path.isAbsolute(upstreamConfig.snapshotDir)
        ? path.resolve(playwrightDir, upstreamConfig.snapshotDir)
        : upstreamConfig.snapshotDir

const outputDir =
    typeof upstreamConfig.outputDir === 'string'
        ? path.isAbsolute(upstreamConfig.outputDir)
            ? upstreamConfig.outputDir
            : path.resolve(playwrightDir, upstreamConfig.outputDir)
        : path.join(playwrightDir, 'test-results')

export default defineConfig({
    ...upstreamConfig,
    testDir: path.join(playwrightDir, 'e2e'),
    testMatch: '**/*.spec.ts',
    snapshotDir,
    outputDir,
    reporter: reporter as typeof upstreamConfig.reporter,
    projects: [
        {
            ...baseProject,
            name: 'chromium',
            testDir: path.join(playwrightDir, 'e2e'),
            testMatch: '**/*.spec.ts',
        },
        {
            ...baseProject,
            name: 'chromium-products',
            testDir: productsDir,
            testMatch: '*/frontend/e2e/**/*.spec.ts',
        },
    ],
})
