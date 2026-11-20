#!/usr/bin/env node
// storybook_footprint.mjs: what each story file a Storybook shard ran used of the repository,
// as an enact reach map in $ENACT_FOOTPRINT_DIR (run_storybook_tests.sh runs it after the
// test-runner when enact records footprints).
//
//   storybook_footprint.mjs <dist> <loads dir> <server url>
//
// The stories run in chromium against the static build, so no process reads the story's
// sources: a footprint joins the URLs its browser context requested (<loads dir>, written by
// the test-runner's enact-loads.ts) with what each output of the build was made from
// (<dist>/enact-chunks.json, vite-enact-chunks-plugin.ts). A chunk stands for every module
// bundled into it (shaken-out code and unused imports included); a copied static file
// (Storybook's staticDirs) for its source. A story file whose page loaded something made from
// sources the build doesn't record (the web workers `build:workers` bundles into .workers) is
// left out: untraced, it runs for every change. Requests elsewhere (other hosts, Storybook's
// own runtime files) hold none of the repository's files.
//
// What the build and the test-runner read that no output holds is every story file's (the
// map's `shared` part): Storybook's own package (its configuration, plugins, the runner's jest
// setup), the frontend's build scripts and manifests the build runs first (build:products,
// build:workers), the products' manifests build:products generates the routes from, and
// every stylesheet no output holds (Sass partials a stylesheet `@use`s: the bundle records
// only the stylesheet).
//
// The map has no outcomes: enact lands it only when the shard passed. $ENACT_FOOTPRINT_TARGETS,
// when set, lists the story files worth recording; the others are left out.
import fs from 'node:fs'
import path from 'node:path'

const RECORDER = 'storybook_footprint.mjs/1'
const rawArgs = process.argv.slice(2)
const positional = []
let runnerStatus = null
let junitPath = null
let skipTagsRaw = process.env.STORYBOOK_SKIP_TAGS ?? 'test-skip'
for (let i = 0; i < rawArgs.length; i += 1) {
    const arg = rawArgs[i]
    if (arg === '--status' && i + 1 < rawArgs.length) {
        runnerStatus = Number.parseInt(rawArgs[++i], 10)
    } else if (arg === '--junit' && i + 1 < rawArgs.length) {
        junitPath = rawArgs[++i]
    } else if (arg === '--skip-tags' && i + 1 < rawArgs.length) {
        skipTagsRaw = rawArgs[++i]
    } else if (arg.startsWith('--')) {
        console.error(`storybook_footprint: unknown flag ${arg}`)
        process.exit(64)
    } else {
        positional.push(arg)
    }
}
const [distArg, loadsArg, serverUrl] = positional
if (!distArg || !loadsArg || !serverUrl) {
    console.error(
        'usage: storybook_footprint.mjs <dist> <loads dir> <server url> [--status <n>] [--junit <xml>] [--skip-tags <csv>]'
    )
    process.exit(64)
}
const skipTags = new Set(
    skipTagsRaw
        .split(',')
        .map((t) => t.trim())
        .filter(Boolean)
)
const root = process.cwd()
const outDir = process.env.ENACT_FOOTPRINT_DIR
if (!outDir) {
    console.error('storybook_footprint: ENACT_FOOTPRINT_DIR is not set')
    process.exit(64)
}
const dist = path.resolve(distArg)
const chunksFile = path.join(dist, 'enact-chunks.json')
if (!fs.existsSync(chunksFile)) {
    // No map from outputs to sources: the story files stay untraced (selection runs them as
    // such), and the tests' own exit decides the shard, not the missing recording.
    console.error(`storybook_footprint: ${chunksFile} is missing (a build without the enact-chunks plugin): no footprints recorded`)
    process.exit(0)
}
const { outputs } = JSON.parse(fs.readFileSync(chunksFile, 'utf8'))
const origin = new URL(serverUrl).origin

// Storybook's staticDirs (.storybook/main.ts): URL prefix -> the directories it serves from.
// node_modules sources hold no repository file; .workers is a build of its own (unrecorded).
const STATIC = [
    ['static/', ['frontend/public/', 'common/storybook/.workers/']],
    ['replay_player_frame/', ['posthog/templates/replay_player_frame/']],
    ['', ['common/storybook/.storybook/public/']],
]
const UNRECORDED_BUILDS = ['common/storybook/.workers/']
// Read whole by the build or the runner: directories, and files (from the checkout's root).
const SHARED_DIRS = ['common/storybook', 'common/tailwind']
const SHARED_FILES = [
    'package.json',
    'pnpm-lock.yaml',
    'pnpm-workspace.yaml',
    'tsconfig.json',
    'frontend/package.json',
    'frontend/tsconfig.json',
    'frontend/build-products.mjs',
    'frontend/workers.config.mjs',
    'frontend/bin/watch-workers.mjs',
    // build:products resolves enum values from it.
    'frontend/src/queries/schema/schema-general.ts',
]
// Where the bundle's stylesheets live: those no output holds are partials.
const STYLESHEET_DIRS = ['frontend', 'products', 'common', 'packages/quill', 'ee/frontend', 'services/mcp/src/ui-apps']
// products/desktop: a pnpm workspace of its own (pnpm-workspace.yaml), never in the bundle.
const STYLESHEET_SKIPPED = ['products/desktop/']
// Never sources: build outputs and installed packages.
const SKIPPED = new Set(['node_modules', 'dist', '.workers', '.turbo', '.cache', '__snapshots__'])

const wanted = (() => {
    const listed = process.env.ENACT_FOOTPRINT_TARGETS
    if (!listed) {
        return null
    }
    return new Set(
        fs
            .readFileSync(listed, 'utf8')
            .split('\n')
            .map((line) => line.trim().split('::')[0])
            .filter(Boolean)
    )
})()

const index = (() => {
    try {
        return JSON.parse(fs.readFileSync(path.join(dist, 'index.json'), 'utf8')).entries ?? {}
    } catch {
        return {}
    }
})()

/** The story file a record is for, from the checkout's root. */
function targetOf(record) {
    if (record.file) {
        return path.relative(root, record.file)
    }
    const importPath = index[record.story]?.importPath
    return importPath ? path.relative(root, path.resolve(root, 'common/storybook', importPath)) : null
}

/** The repository files a same-origin path was served from, or why it can't say. */
function sourcesOf(urlPath) {
    if (outputs[urlPath]) {
        // An output made from installed packages only holds none.
        return { files: outputs[urlPath], output: true }
    }
    for (const [prefix, dirs] of STATIC) {
        if (!urlPath.startsWith(prefix)) {
            continue
        }
        for (const dir of dirs) {
            const file = dir + urlPath.slice(prefix.length)
            if (fs.existsSync(path.join(root, file)) && fs.statSync(path.join(root, file)).isFile()) {
                if (UNRECORDED_BUILDS.some((built) => file.startsWith(built))) {
                    return { unrecorded: file }
                }
                return { files: [file] }
            }
        }
    }
    return { files: [] }
}

/** The files under `dir` (from the checkout's root) `keep` accepts, build outputs left out. */
function walk(dir, keep, found = []) {
    let entries
    try {
        entries = fs.readdirSync(path.join(root, dir), { withFileTypes: true })
    } catch {
        return found
    }
    for (const entry of entries) {
        const rel = `${dir}/${entry.name}`
        if (entry.isDirectory()) {
            if (!SKIPPED.has(entry.name)) {
                walk(rel, keep, found)
            }
        } else if (entry.isFile() && keep(rel)) {
            found.push(rel)
        }
    }
    return found
}

/** What every story file's footprint holds (above). */
function sharedFiles() {
    const held = new Set(Object.values(outputs).flat())
    const files = new Set(SHARED_FILES.filter((file) => fs.existsSync(path.join(root, file))))
    for (const dir of SHARED_DIRS) {
        walk(dir, () => true).forEach((file) => files.add(file))
    }
    for (const entry of fs.readdirSync(path.join(root, 'products'), { withFileTypes: true })) {
        const manifest = `products/${entry.name}/manifest.tsx`
        if (entry.isDirectory() && fs.existsSync(path.join(root, manifest))) {
            files.add(manifest)
        }
    }
    for (const dir of STYLESHEET_DIRS) {
        walk(
            dir,
            (file) =>
                /\.(s[ac]ss|css|less)$/.test(file) &&
                !held.has(file) &&
                !STYLESHEET_SKIPPED.some((skipped) => file.startsWith(skipped))
        ).forEach((file) => files.add(file))
    }
    return [...files].sort()
}

const footprints = new Map()
const unrecorded = new Map()
const unmapped = new Set()
for (const name of fs.existsSync(loadsArg) ? fs.readdirSync(loadsArg) : []) {
    if (!name.endsWith('.jsonl')) {
        continue
    }
    for (const line of fs.readFileSync(path.join(loadsArg, name), 'utf8').split('\n')) {
        if (!line.trim()) {
            continue
        }
        const record = JSON.parse(line)
        const target = targetOf(record)
        if (!target || (wanted && !wanted.has(target))) {
            continue
        }
        const files = footprints.get(target) ?? new Set([target])
        footprints.set(target, files)
        for (const url of record.urls) {
            let parsed
            try {
                parsed = new URL(url)
            } catch {
                continue
            }
            if (parsed.origin !== origin) {
                continue
            }
            const urlPath = decodeURIComponent(parsed.pathname).replace(/^\/+/, '')
            const found = sourcesOf(urlPath)
            if (found.unrecorded) {
                unrecorded.set(target, found.unrecorded)
            } else if (found.files.length) {
                found.files.forEach((file) => files.add(file))
            } else if (!found.output) {
                unmapped.add(urlPath)
            }
        }
    }
}

function decodeXmlAttr(value) {
    return value
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&amp;/g, '&')
}

function parseXmlAttrs(raw) {
    const attrs = {}
    for (const match of raw.matchAll(/([A-Za-z_][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
        attrs[match[1]] = decodeXmlAttr(match[2] ?? match[3] ?? '')
    }
    return attrs
}

function parseNonNegInt(value) {
    if (typeof value !== 'string' || !/^\d+$/.test(value)) {
        return null
    }
    return Number.parseInt(value, 10)
}

/** Whether `dist/index.json` lists any runnable (non-skipped) story entry for `target`. */
function indexHasRunnableStory(target) {
    for (const entry of Object.values(index)) {
        if (!entry || entry.type !== 'story' || !entry.importPath) {
            continue
        }
        const entryTarget = path.relative(root, path.resolve(root, 'common/storybook', entry.importPath))
        if (entryTarget !== target) {
            continue
        }
        const tags = Array.isArray(entry.tags) ? entry.tags : []
        if (!tags.some((tag) => skipTags.has(tag))) {
            return true
        }
    }
    return false
}

/**
 * Story files positively proved by `junit.xml` to have executed cleanly in this shard with every
 * story skipped (zero errors, zero failures, every testcase `<skipped>`). Fail closed: returns
 * empty when the runner exited non-zero, `junit.xml` is missing/malformed, or any story ran.
 */
function provenSkippedOnlyTargets() {
    if (runnerStatus !== 0 || !junitPath || !fs.existsSync(junitPath)) {
        return []
    }
    let xml
    try {
        xml = fs.readFileSync(junitPath, 'utf8')
    } catch {
        return []
    }
    if (!xml.includes('<testsuites') && !xml.includes('<testsuite')) {
        return []
    }
    const proved = new Set()
    const suiteRe = /<testsuite\b([^>]*?)(?:\/>|>([\s\S]*?)<\/testsuite>)/g
    for (const match of xml.matchAll(suiteRe)) {
        const attrs = parseXmlAttrs(match[1])
        const body = match[2] ?? ''
        const suiteName = attrs.name
        if (!suiteName) {
            continue
        }
        const errors = parseNonNegInt(attrs.errors)
        const failures = parseNonNegInt(attrs.failures)
        const tests = parseNonNegInt(attrs.tests)
        const skipped = parseNonNegInt(attrs.skipped ?? '0')
        if (errors !== 0 || failures !== 0 || tests === null || skipped === null) {
            continue
        }
        const target = path.isAbsolute(suiteName)
            ? path.relative(root, suiteName)
            : path.relative(root, path.resolve(root, 'common/storybook', suiteName))
        if (!target || target.startsWith('..') || !fs.existsSync(path.join(root, target))) {
            continue
        }
        if (wanted && !wanted.has(target)) {
            continue
        }
        if (footprints.has(target) || unrecorded.has(target)) {
            continue
        }
        const testcases = [...body.matchAll(/<testcase\b([^>]*?)(?:\/>|>([\s\S]*?)<\/testcase>)/g)]
        if (tests > 0) {
            if (skipped !== tests || testcases.length !== tests) {
                continue
            }
            const allSkipped = testcases.every((tc) => {
                const tcBody = tc[2] ?? ''
                return (
                    /<skipped(?:\s|\/|>)/.test(tcBody) &&
                    !/<failure(?:\s|\/|>)/.test(tcBody) &&
                    !/<error(?:\s|\/|>)/.test(tcBody)
                )
            })
            if (!allSkipped) {
                continue
            }
            proved.add(target)
        } else if (tests === 0 && skipped === 0 && testcases.length === 0 && !indexHasRunnableStory(target)) {
            proved.add(target)
        }
    }
    return [...proved].sort()
}

const skippedOnly = provenSkippedOnlyTargets()
const targets = {}
for (const [target, files] of [...footprints].sort(([a], [b]) => a.localeCompare(b))) {
    if (!unrecorded.has(target)) {
        const sorted = [...files].sort()
        targets[target] = { files: sorted, loaded: sorted }
    }
}
for (const target of skippedOnly) {
    targets[target] = { files: [target], loaded: [target] }
}
fs.mkdirSync(outDir, { recursive: true })
const shard = process.env.ENACT_SHARD_INDEX ?? '1'
const out = path.join(outDir, `storybook-shard${shard}-${process.pid}.json`)
const shared = sharedFiles()
fs.writeFileSync(
    out,
    JSON.stringify({ version: 1, recorder: RECORDER, shared: { files: shared, loaded: shared }, targets })
)
fs.writeFileSync(
    out.replace(/\.json$/, '.stats'),
    JSON.stringify(
        {
            targets: Object.keys(targets).length,
            shared: shared.length,
            skipped_only: skippedOnly,
            left_out: Object.fromEntries(unrecorded),
            unmapped: [...unmapped].sort(),
        },
        null,
        1
    )
)
console.error(
    `storybook_footprint: ${Object.keys(targets).length} story files` +
        (skippedOnly.length ? ` (${skippedOnly.length} proven all-skipped)` : '') +
        (unrecorded.size ? `, ${unrecorded.size} left out (unrecorded builds)` : '') +
        ` -> ${out}`
)
