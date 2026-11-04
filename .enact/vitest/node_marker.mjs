// A vitest reporter for enact's Node recorder (vitest.sh adds it under `--node-functions`):
// it adds node_marker_setup.mjs as the first setup file of each project whose tests
// run in Node workers (a pool of workerd's, @cloudflare/vitest-pool-workers, has no
// recorder). Run from a copy under the project root's node_modules: vite loads no setup file
// from outside its workspace (packages/agent is one of its own). Written only when it
// differs: the tests read it, and a rewrite in every run changed a file the last run's
// footprints hold as they ran.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SOURCE = fs.readFileSync(fileURLToPath(new URL('./node_marker_setup.mjs', import.meta.url)));
const NODE_POOLS = new Set(['forks', 'threads', 'vmForks', 'vmThreads']);

export default class EnactNodeMarker {
  onInit(vitest) {
    const projects = vitest.projects?.length ? vitest.projects : [vitest.getRootProject?.()].filter(Boolean);
    for (const project of projects) {
      const config = project.config;
      const setupFiles = config?.setupFiles;
      if (!Array.isArray(setupFiles) || (config.pool !== undefined && !NODE_POOLS.has(config.pool))) continue;
      const marker = path.join(config.root, 'node_modules', '.enact', 'vitest-node-marker.mjs');
      let copy = null;
      try {
        copy = fs.readFileSync(marker);
      } catch {}
      if (!copy || !copy.equals(SOURCE)) {
        fs.mkdirSync(path.dirname(marker), { recursive: true });
        fs.writeFileSync(marker, SOURCE);
      }
      if (!setupFiles.includes(marker)) setupFiles.unshift(marker);
    }
  }
}
