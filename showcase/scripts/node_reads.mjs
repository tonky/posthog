// node-reads.mjs: what a Node.js process reads of the repository, for enact's footprints of the
// Playwright e2e specs (e2e-footprint.mjs; posthog's live jobs record the same way, its
// showcase/scripts/node_reads.mjs). Preloaded with NODE_OPTIONS="--import <this file>" while
// $ENACT_NODE_READS names a directory: every Node process a spec's run starts
// (run-local-isolated.mjs, pnpm, the n8n server and its task runner, Playwright's runner and
// workers) writes `<dir>/<pid>-0.json` at exit, `{reads, present, probes, dirs, served}`, paths
// from $ENACT_FOOTPRINT_ROOT:
//   reads    files opened, copied, or loaded as modules (the loader's own reads included)
//   present  files a stat found (their size or times may count)
//   probes   paths found missing, or asked about by `exists`/`access` (adding or deleting one
//            may change what the process does, editing it doesn't)
//   dirs     directories listed
//   served   files read from the n8n server's static cache ($N8N_USER_FOLDER/.cache/n8n/public,
//            relative to it): the server copies the editor's build there as it starts (a
//            write) and reads it as the browser requests it, so these are the browser's fetches
// Paths in node_modules and dot directories are no source of the repository's. A process ended
// by a signal writes nothing: e2e-footprint.mjs turns a process that started (its `.started`
// marker) and left no record into an incomplete footprint.
//
// A child started with an environment of its own (n8n's task runner gets an allowlist, without
// NODE_OPTIONS) gets this preload's variables back, so it records too.
//
// Worker threads load this preload too (NODE_OPTIONS reaches them), but one may end with its
// process without an exit event: a worker appends each entry to `<dir>/<pid>-<threadId>.jsonl`
// (`[set, path]` lines) before the call that made it, so the log holds all it read whenever it
// ends. Its parent writes the worker's `.started` marker as it starts it (so does the worker),
// so a worker that never ran the preload leaves a marker without a log: incomplete.
//
// What it can't see: reads by native code (addons, a child that isn't Node.js) and by a
// process started without NODE_OPTIONS (no marker either).
import childProcess from 'node:child_process'
import fs from 'node:fs'
import { registerHooks, syncBuiltinESMExports } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import workerThreads, { isMainThread, threadId } from 'node:worker_threads'

const dir = process.env.ENACT_NODE_READS
const repo = process.env.ENACT_FOOTPRINT_ROOT
const self = fileURLToPath(import.meta.url)

if (dir && repo) {
    const root = path.resolve(repo) + path.sep
    const real = { ...fs, promises: { ...fs.promises } }
    const sets = { reads: new Set(), present: new Set(), probes: new Set(), dirs: new Set(), served: new Set() }
    let busy = false
    // The n8n server's static cache (InstanceSettings.staticCacheDir), as given and resolved.
    const servedRoots = []
    const userFolder = process.env.N8N_USER_FOLDER
    if (userFolder) {
        servedRoots.push(path.join(path.resolve(userFolder), '.cache/n8n/public') + path.sep)
        try {
            servedRoots.push(path.join(fs.realpathSync(userFolder), '.cache/n8n/public') + path.sep)
        } catch {
            // not made yet: the path as given
        }
    }

    const absoluteOf = (target) => {
        try {
            if (target instanceof URL) {
                return path.resolve(fileURLToPath(target))
            } else if (typeof target === 'string') {
                return path.resolve(target.startsWith('file:') ? fileURLToPath(target) : target)
            } else if (Buffer.isBuffer(target)) {
                return path.resolve(target.toString())
            }
        } catch {
            // not a path
        }
        return null // a descriptor: its open was recorded
    }
    const relative = (target) => {
        const absolute = absoluteOf(target)
        if (absolute === null) {
            return null
        }
        const served = servedRoots.find((prefix) => absolute.startsWith(prefix))
        if (served) {
            return { served: absolute.slice(served.length).split(path.sep).join('/') }
        }
        if (!absolute.startsWith(root)) {
            return null
        }
        const rel = absolute.slice(root.length)
        const parts = rel.split(path.sep)
        if (parts.includes('node_modules') || parts.some((part) => part.startsWith('.'))) {
            return null
        }
        return parts.join('/')
    }
    // A worker's log (see above): opened as the preload starts, appended to as entries come.
    let log = null
    const add = (set, rel) => {
        if (sets[set].has(rel)) {
            return
        }
        sets[set].add(rel)
        if (log !== null) {
            real.writeSync(log, JSON.stringify([set, rel]) + '\n')
        }
    }
    const note = (set, target) => {
        const rel = relative(target)
        if (rel && typeof rel === 'object') {
            if (set === 'reads') {
                add('served', rel.served)
            }
        } else if (rel) {
            add(set, rel)
        }
    }
    // A stat-like call: a file found is present, a missing path a probe; directories say nothing.
    const found = (target, isFile) => {
        const rel = relative(target)
        if (rel && typeof rel === 'string') {
            if (isFile === undefined) {
                add('probes', rel)
            } else if (isFile) {
                add('present', rel)
            }
        }
    }
    // Whether `target` is a file (undefined: missing), by the unpatched stat.
    const kind = (target) => {
        try {
            return real.statSync(target, { throwIfNoEntry: false })?.isFile()
        } catch {
            return undefined
        }
    }
    const wrap = (owner, name, record) => {
        const original = owner[name]
        if (typeof original !== 'function') {
            return
        }
        const wrapped = function (target, ...rest) {
            if (!busy) {
                busy = true
                try {
                    record(target, rest)
                } catch {
                    // never fail the process for its record
                } finally {
                    busy = false
                }
            }
            return original.call(this, target, ...rest)
        }
        // What hangs off the original (`realpath.native`, `util.promisify.custom`).
        for (const key of Reflect.ownKeys(original)) {
            if (!['length', 'name', 'prototype', 'arguments', 'caller'].includes(key)) {
                Object.defineProperty(wrapped, key, Object.getOwnPropertyDescriptor(original, key))
            }
        }
        owner[name] = wrapped
    }
    const reading = (target, rest) => {
        // An open for writing reads nothing.
        const flags = typeof rest[0] === 'object' && rest[0] ? rest[0].flag ?? rest[0].flags : rest[0]
        if (typeof flags === 'string' && /[wa]/.test(flags) && !flags.includes('+')) {
            return
        }
        const isFile = kind(target)
        if (isFile === undefined) {
            found(target, undefined)
        } else if (isFile) {
            note('reads', target)
        }
    }
    const stating = (target) => found(target, kind(target))
    const listing = (target) => note('dirs', target)

    // A presence predicate: adding or deleting the path matters, editing it doesn't.
    const probing = (target) => {
        const rel = relative(target)
        if (rel && typeof rel === 'string') {
            add('probes', rel)
        }
    }
    const copying = (source) => {
        const isFile = kind(source)
        if (isFile === undefined) {
            found(source, undefined)
        } else if (isFile) {
            note('reads', source)
        } else {
            readTree(source)
        }
    }
    // A directory copied whole (`cp -r`): each file in it, and its listings.
    const readTree = (directory) => {
        note('dirs', directory)
        for (const entry of real.readdirSync(directory, { withFileTypes: true })) {
            const child = path.join(directory, entry.name)
            if (entry.isDirectory()) {
                readTree(child)
            } else {
                note('reads', child)
            }
        }
    }

    for (const name of ['readFileSync', 'readFile', 'openSync', 'open', 'createReadStream']) {
        wrap(fs, name, reading)
    }
    for (const name of ['readFile', 'open']) {
        wrap(fs.promises, name, reading)
    }
    for (const name of ['copyFileSync', 'copyFile', 'cpSync', 'cp']) {
        wrap(fs, name, copying)
    }
    for (const name of ['copyFile', 'cp']) {
        wrap(fs.promises, name, copying)
    }
    for (const name of ['statSync', 'lstatSync', 'stat', 'lstat', 'realpathSync', 'realpath']) {
        wrap(fs, name, stating)
    }
    for (const name of ['stat', 'lstat', 'realpath']) {
        wrap(fs.promises, name, stating)
    }
    for (const name of ['existsSync', 'exists', 'accessSync', 'access']) {
        wrap(fs, name, probing)
    }
    wrap(fs.promises, 'access', probing)
    for (const name of ['readdirSync', 'readdir', 'opendirSync', 'opendir']) {
        wrap(fs, name, listing)
    }
    for (const name of ['readdir', 'opendir']) {
        wrap(fs.promises, name, listing)
    }

    // Children given an environment of their own: this preload's variables back in it.
    const recording = {
        ENACT_NODE_READS: dir,
        ENACT_FOOTPRINT_ROOT: repo,
    }
    const withPreload = (options) => {
        if (!options || typeof options !== 'object' || !options.env || options.env.ENACT_NODE_READS) {
            return options
        }
        const env = { ...options.env, ...recording }
        const preload = `--import ${self}`
        if (!String(env.NODE_OPTIONS ?? '').includes(preload)) {
            env.NODE_OPTIONS = env.NODE_OPTIONS ? `${preload} ${env.NODE_OPTIONS}` : preload
        }
        return { ...options, env }
    }
    // (file, args?, options?) callers: the options are the last object argument.
    const respawn = (name) => {
        const original = childProcess[name]
        if (typeof original !== 'function') {
            return
        }
        childProcess[name] = function (...args) {
            const at = args.findLastIndex((arg) => arg && typeof arg === 'object' && !Array.isArray(arg))
            if (at > 0) {
                args[at] = withPreload(args[at])
            }
            return original.apply(this, args)
        }
    }
    for (const name of ['spawn', 'spawnSync', 'execFile', 'execFileSync', 'fork', 'exec', 'execSync']) {
        respawn(name)
    }

    // A process' or worker's `.started` marker: a record (or log) is expected beside it.
    const marker = (id, argv) => {
        try {
            real.mkdirSync(dir, { recursive: true })
            real.writeFileSync(path.join(dir, `${process.pid}-${id}.started`), argv)
        } catch {
            // no marker: nothing expects its record
        }
    }
    const Worker = workerThreads.Worker
    workerThreads.Worker = class extends Worker {
        constructor(...args) {
            super(...args)
            marker(this.threadId, `a worker thread (${String(args[0]).slice(0, 200)})`)
        }
    }
    syncBuiltinESMExports()

    // Modules the loader reads itself (ESM, and CommonJS through the hooks): their URLs.
    registerHooks({
        load(url, context, nextLoad) {
            if (url.startsWith('file:')) {
                note('reads', url)
            }
            return nextLoad(url, context)
        },
    })

    if (isMainThread) {
        let written = false
        const write = () => {
            if (written) {
                return
            }
            written = true
            busy = true
            try {
                real.mkdirSync(dir, { recursive: true })
                const record = Object.fromEntries(Object.entries(sets).map(([name, set]) => [name, [...set].sort()]))
                const file = path.join(dir, `${process.pid}-0.json`)
                real.writeFileSync(file + '.tmp', JSON.stringify(record))
                real.renameSync(file + '.tmp', file)
            } catch {
                // the process' `.started` marker stays without its record: incomplete
            }
        }
        marker(0, process.argv.join(' '))
        process.on('exit', write)
        // A runner ending its workers with a signal: record, then end as the signal would, unless
        // the process handles it itself.
        for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
            process.once(signal, () => {
                write()
                if (process.listenerCount(signal) === 0) {
                    process.kill(process.pid, signal)
                }
            })
        }
    } else {
        // Its own marker too: a worker started through a Worker class taken before this preload
        // patched it has none from its parent.
        marker(threadId, `a worker thread (${process.argv.slice(1).join(' ').slice(0, 200)})`)
        try {
            log = real.openSync(path.join(dir, `${process.pid}-${threadId}.jsonl`), 'a')
            // What it read before the log opened (the modules this preload's own imports loaded).
            for (const [set, entries] of Object.entries(sets)) {
                for (const rel of entries) {
                    real.writeSync(log, JSON.stringify([set, rel]) + '\n')
                }
            }
        } catch {
            // its parent's marker stays without a log: incomplete
        }
    }
}

// Playwright reporter (`--reporter=list,<this file>`): writes one JSON line per spec file to
// $ENACT_SKIPS_FILE, saying whether the run skipped any test of it (`skipped_on`).
export default class EnactAttribution {
    printsToStdio() {
        return false
    }

    onBegin(_config, suite) {
        this.suite = suite
    }

    onEnd() {
        const out = process.env.ENACT_SKIPS_FILE
        if (!out || !this.suite) {
            return
        }
        const files = new Map()
        for (const test of this.suite.allTests()) {
            const file = files.get(test.location.file) ?? { tests: 0, skipped: 0, failed: 0 }
            const outcome = test.outcome()
            file.tests += 1
            if (outcome === 'skipped') {
                file.skipped += 1
            }
            if (outcome === 'unexpected') {
                file.failed += 1
            }
            files.set(test.location.file, file)
        }
        const lines = [...files].map(([target, { tests, skipped, failed }]) => {
            const outcome = failed ? 'failed' : skipped === tests ? 'skipped' : 'passed'
            return `${JSON.stringify({ target, outcome, skipped: skipped > 0, reads: [] })}\n`
        })
        fs.appendFileSync(out, lines.join(''))
    }
}
