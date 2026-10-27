import * as fs from 'fs'
import * as path from 'path'
import type { Plugin } from 'vite'

/**
 * enact's Storybook footprints (showcase/scripts/storybook_footprint.mjs): the browser runs the
 * bundle, never the repository's files, so a story file's footprint joins the build's outputs
 * its page fetched with what this writes, each output file of the build and the repository
 * files it was made from (`dist/enact-chunks.json`):
 *   - a chunk: every module in it, those whose code was shaken out included;
 *   - a module no output holds (unused, shaken out whole): every output holding a module that
 *     imports it, up its importers, as an added side effect would land there;
 *   - a CSS file: the stylesheets of the chunks importing it; an asset (image, font, wasm):
 *     the files it was copied from.
 * What the build reads that is no module (Sass partials, configuration) is every story's
 * (storybook_footprint.mjs).
 * Paths are the repository's, node_modules and virtual modules left out (no footprint holds
 * them). Written by every build, so a build made without recording serves a recording too.
 */
export function enactChunksPlugin(repoRoot: string): Plugin {
    const root = repoRoot.endsWith(path.sep) ? repoRoot : repoRoot + path.sep
    let viteRoot = repoRoot

    const inRepo = (id: string): string | undefined => {
        const file = id.split('?')[0].split('#')[0]
        if (file.startsWith('\0') || !path.isAbsolute(file) || !file.startsWith(root)) {
            return undefined
        }
        const relative = file.slice(root.length)
        // A module with no file (Storybook's iframe.html entry) is no file of the repository's.
        return relative.split(path.sep).includes('node_modules') || !fs.existsSync(file) ? undefined : relative
    }
    const isStylesheet = (id: string): boolean => /\.(css|scss|sass|less|pcss|styl)$/.test(id.split('?')[0])

    return {
        name: 'enact-chunks',
        apply: 'build',
        configResolved(config) {
            viteRoot = config.root
        },
        generateBundle(_options, bundle) {
            const outputs: Record<string, Set<string>> = {}
            const add = (output: string, id: string | null | undefined): void => {
                const file = id ? inRepo(id) : undefined
                if (file) {
                    ;(outputs[output] ??= new Set()).add(file)
                }
            }
            // Module id -> the outputs holding it.
            const holders = new Map<string, Set<string>>()
            for (const [fileName, item] of Object.entries(bundle)) {
                if (item.type === 'chunk') {
                    outputs[fileName] ??= new Set()
                    const ids = new Set([...Object.keys(item.modules), ...(item.moduleIds ?? [])])
                    if (item.facadeModuleId) {
                        ids.add(item.facadeModuleId)
                    }
                    for (const id of ids) {
                        add(fileName, id)
                        if (!holders.has(id)) {
                            holders.set(id, new Set())
                        }
                        holders.get(id)!.add(fileName)
                    }
                    const meta = (item as { viteMetadata?: { importedCss?: Set<string> } }).viteMetadata
                    for (const css of meta?.importedCss ?? []) {
                        for (const id of ids) {
                            if (isStylesheet(id)) {
                                add(css, id)
                            }
                        }
                    }
                } else {
                    const sources = [
                        ...((item as { originalFileNames?: string[] }).originalFileNames ?? []),
                        ...((item as { originalFileName?: string | null }).originalFileName
                            ? [(item as { originalFileName: string }).originalFileName]
                            : []),
                    ]
                    for (const source of sources) {
                        add(fileName, path.isAbsolute(source) ? source : path.resolve(viteRoot, source))
                    }
                    outputs[fileName] ??= new Set()
                }
            }
            // Modules no output holds: the outputs of their nearest held importers.
            for (const id of this.getModuleIds()) {
                if (holders.has(id) || !inRepo(id)) {
                    continue
                }
                const seen = new Set([id])
                const queue = [id]
                const found = new Set<string>()
                while (queue.length) {
                    const info = this.getModuleInfo(queue.shift()!)
                    for (const importer of [...(info?.importers ?? []), ...(info?.dynamicImporters ?? [])]) {
                        if (seen.has(importer)) {
                            continue
                        }
                        seen.add(importer)
                        const held = holders.get(importer)
                        if (held) {
                            held.forEach((output) => found.add(output))
                        } else {
                            queue.push(importer)
                        }
                    }
                }
                found.forEach((output) => add(output, id))
            }
            const written = Object.fromEntries(
                Object.entries(outputs)
                    .sort(([a], [b]) => a.localeCompare(b))
                    .map(([output, files]) => [output, [...files].sort()])
            )
            this.emitFile({
                type: 'asset',
                fileName: 'enact-chunks.json',
                source: JSON.stringify({ version: 1, outputs: written }),
            })
        },
    }
}
