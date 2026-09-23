#!/usr/bin/env node
import { spawnSync } from 'child_process'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const scriptPath = fileURLToPath(import.meta.url)
const frontendDir = path.resolve(path.dirname(scriptPath), '..')
const repoRoot = path.resolve(frontendDir, '..')
const localKeaTypegenBin = path.resolve(
    frontendDir,
    'node_modules',
    '.bin',
    process.platform === 'win32' ? 'kea-typegen.cmd' : 'kea-typegen'
)

const args = process.argv.slice(2)

// If no arguments provided, execute full check
if (args.length === 0) {
    runFullCheck()
}

const GLOBAL_CONFIG_PATTERNS = [
    'tsconfig.json',
    'tsconfig.kea-typegen.json',
    'pnpm-lock.yaml',
    'package.json',
    '.kearc',
]

const changedFiles = args.map((f) => f.replace(/\\/g, '/'))

// Check if any global configs changed
const hasGlobalConfigChange = changedFiles.some((f) => GLOBAL_CONFIG_PATTERNS.some((cfg) => f.endsWith(cfg)))

if (hasGlobalConfigChange) {
    runFullCheck()
}

// Filter for Kea logic files
const logicFiles = []

for (const file of changedFiles) {
    // 1. Filename heuristic (*Logic.ts, *Logic.tsx, *LogicType.ts)
    if (/Logic(Type)?\.[jt]sx?$/.test(file)) {
        logicFiles.push(file)
        continue
    }

    // 2. Content check for any changed TS file that imports kea
    if (/\.[jt]sx?$/.test(file)) {
        const absPath = path.isAbsolute(file) ? file : path.resolve(repoRoot, file)
        if (fs.existsSync(absPath)) {
            try {
                const content = fs.readFileSync(absPath, 'utf8')
                if (content.includes("from 'kea'") || content.includes('from "kea"') || content.includes('kea<')) {
                    logicFiles.push(file)
                }
            } catch {
                // Ignore read errors
            }
        }
    }
}

if (logicFiles.length === 0) {
    process.exit(0)
}

const nodeOptions = [process.env.NODE_OPTIONS, '--max-old-space-size=4096'].filter(Boolean).join(' ')

let hasError = false
for (const logicFile of logicFiles) {
    const absPath = path.isAbsolute(logicFile) ? logicFile : path.resolve(repoRoot, logicFile)
    if (!fs.existsSync(absPath)) {
        continue
    }

    const result = spawnSync(
        fs.existsSync(localKeaTypegenBin) ? localKeaTypegenBin : 'kea-typegen',
        ['check', '--show-ts-errors', '--file', absPath],
        {
            cwd: repoRoot,
            env: {
                ...process.env,
                NODE_OPTIONS: nodeOptions,
            },
            stdio: 'inherit',
        }
    )

    if (result.status !== 0) {
        hasError = true
    }
}

if (hasError) {
    process.exit(1)
}

process.exit(0)

function runFullCheck() {
    const nodeOptions = [process.env.NODE_OPTIONS, '--max-old-space-size=16384'].filter(Boolean).join(' ')
    const result = spawnSync(fs.existsSync(localKeaTypegenBin) ? localKeaTypegenBin : 'kea-typegen', ['check'], {
        cwd: repoRoot,
        env: {
            ...process.env,
            NODE_OPTIONS: nodeOptions,
        },
        stdio: 'inherit',
    })
    if (result.error) {
        console.error(`Unable to start kea-typegen: ${result.error.message}`)
    }
    process.exit(result.status ?? 1)
}
