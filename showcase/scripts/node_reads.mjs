// node_reads.mjs: what a Node.js process reads of the repository, for enact's footprints of the
// jobs that drive a live PostHog (live_footprint.py). Preloaded with
// NODE_OPTIONS="--import <this file>" while $ENACT_NODE_READS names a directory: every Node
// process the test runner starts (its workers, pnpm, the runner itself) writes
// `<dir>/<pid>-0.json` at exit, `{reads, present, probes, dirs}`, paths from
// $ENACT_FOOTPRINT_ROOT:
//   reads    files opened, copied, or loaded as modules (the loader's own reads included)
//   present  files a stat found (their size or times may count)
//   probes   paths found missing, or asked about by `exists`/`access` (adding or deleting one
//            may change what the process does, editing it doesn't)
//   dirs     directories listed
// Paths in node_modules and dot directories are no source of the repository's. A process ended
// by a signal writes nothing: live_footprint.py turns a process that started (its `.started`
// marker) and left no record into an incomplete footprint.
//
// Worker threads load this preload too (NODE_OPTIONS reaches them), but one ends with its
// process without an exit event (esbuild's sync-transform thread, which tsx starts on a cold
// cache, never returns): a worker appends each entry to `<dir>/<pid>-<threadId>.jsonl`
// (`[set, path]` lines) before the call that made it, so the log holds all it read whenever it
// ends. Its parent writes the worker's `.started` marker as it starts it (so does the worker),
// so a worker that never ran the preload leaves a marker without a log: incomplete.
//
// What it can't see: reads by native code (addons, a child that isn't Node.js) and by a
// process started without NODE_OPTIONS (no marker either).
import fs from 'node:fs'
import { registerHooks, syncBuiltinESMExports } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import workerThreads, { isMainThread, threadId } from 'node:worker_threads'

const dir = process.env.ENACT_NODE_READS
const repo = process.env.ENACT_FOOTPRINT_ROOT

if (dir && repo) {
    const root = path.resolve(repo) + path.sep
    const real = { ...fs, promises: { ...fs.promises } }
    const sets = { reads: new Set(), present: new Set(), probes: new Set(), dirs: new Set() }
    let busy = false

    const relative = (target) => {
        let file
        try {
            if (target instanceof URL) {
                file = fileURLToPath(target)
            } else if (typeof target === 'string') {
                file = target.startsWith('file:') ? fileURLToPath(target) : target
            } else if (Buffer.isBuffer(target)) {
                file = target.toString()
            } else {
                return null // a descriptor: its open was recorded
            }
        } catch {
            return null
        }
        const absolute = path.resolve(file)
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
        if (rel) {
            add(set, rel)
        }
    }
    // A stat-like call: a file found is present, a missing path a probe; directories say nothing.
    const found = (target, isFile) => {
        const rel = relative(target)
        if (rel) {
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
        const flags = typeof rest[0] === 'object' && rest[0] ? rest[0].flag : rest[0]
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
    const probing = (target) => note('probes', target)
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
