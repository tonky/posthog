import type { StorybookConfig } from '@storybook/react-vite'
import { fileURLToPath } from 'node:url'
import * as path from 'path'
import { mergeConfig } from 'vite'

import upstream from '../.storybook/main.ts'
import { enactChunksPlugin } from '../.storybook/plugins/vite-enact-chunks-plugin.ts'

/**
 * enact's Storybook configuration: upstream's (.storybook/main.ts) as it is, plus the build's
 * dist/enact-chunks.json (vite-enact-chunks-plugin.ts), which storybook_footprint.mjs joins with
 * what each story file's browser requested. showcase/scripts/run_storybook_tests.sh builds and
 * tests with `-c .storybook-enact`; upstream's files stay unpatched (F-honest-no-patched-upstream).
 * This directory sits beside upstream's, so Vite's root (the config dir's parent) and its paths
 * are upstream's; the relative paths (stories, staticDirs) are resolved from upstream's dir.
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const UPSTREAM_DIR = path.resolve(__dirname, '..', '.storybook')
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..')

const fromUpstream = (p: string): string => (path.isAbsolute(p) ? p : path.relative(__dirname, path.resolve(UPSTREAM_DIR, p)))

type StaticDir = NonNullable<StorybookConfig['staticDirs']> extends (infer D)[] ? D : never
type Stories = Extract<StorybookConfig['stories'], unknown[]>[number]

const config: StorybookConfig = {
    ...upstream,
    stories: (upstream.stories as Stories[]).map((entry) =>
        typeof entry === 'string' ? fromUpstream(entry) : { ...entry, directory: fromUpstream(entry.directory) }
    ),
    staticDirs: ((upstream.staticDirs ?? []) as StaticDir[]).map((dir) =>
        typeof dir === 'string' ? fromUpstream(dir) : { ...dir, from: fromUpstream(dir.from) }
    ),
    viteFinal: async (viteConfig, options) =>
        mergeConfig(upstream.viteFinal ? await upstream.viteFinal(viteConfig, options) : viteConfig, {
            plugins: [enactChunksPlugin(REPO_ROOT)],
        }),
}

export default config
