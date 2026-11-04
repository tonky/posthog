'use strict';
// Runtime preload for Storybook and Playwright E2E runs (loaded via NODE_OPTIONS --require).
// Replaces upstream test/config patches for:
// - STORYBOOK_SNAPSHOTS_DIR (0005): redirects common/storybook/.storybook/test-runner.ts snapshots
// - PLAYWRIGHT_RESULTS_DIR & BASE_URL (0008): redirects Playwright reports/snapshots/baseURL
// - PGPORT (0014): redirects upstream's default Postgres port in E2E specs

const childProcess = require('node:child_process');
const Module = require('node:module');
const net = require('node:net');
const path = require('node:path');

const origResolve = path.resolve.bind(path);
const DEFAULT_PG_NUM = 5400 + 32;
const DEFAULT_PG = String(DEFAULT_PG_NUM);

if (process.env.STORYBOOK_SNAPSHOTS_DIR) {
    path.origResolve = origResolve;
    path.resolve = function (...args) {
        if (args.length > 0 && args[args.length - 1] === '../../../frontend/__snapshots__') {
            return origResolve(process.env.STORYBOOK_SNAPSHOTS_DIR);
        }
        return origResolve(...args);
    };
}

if (process.env.PGPORT && process.env.PGPORT !== DEFAULT_PG) {
    const pgPort = process.env.PGPORT;
    const defaultPgUrl = `postgresql://posthog:posthog@127.0.0.1:${DEFAULT_PG}/posthog`;
    const targetPgUrl = `postgresql://posthog:posthog@127.0.0.1:${pgPort}/posthog`;
    const singleQuotePortRe = new RegExp(`port:\\s*'${DEFAULT_PG}'`, 'g');
    const doubleQuotePortRe = new RegExp(`"port":\\s*"${DEFAULT_PG}"`, 'g');

    const origExecFileSync = childProcess.execFileSync;
    childProcess.execFileSync = function (file, args, options) {
        if (file === 'psql' && Array.isArray(args)) {
            args = args.map((arg) => (typeof arg === 'string' ? arg.replace(defaultPgUrl, targetPgUrl) : arg));
        }
        return origExecFileSync.call(this, file, args, options);
    };

    const origConnect = net.Socket.prototype.connect;
    net.Socket.prototype.connect = function (...args) {
        if (args.length > 0 && typeof args[0] === 'object' && args[0] !== null) {
            const opts = args[0];
            const host = opts.host || 'localhost';
            if ((host === '127.0.0.1' || host === 'localhost') && Number(opts.port) === DEFAULT_PG_NUM) {
                args[0] = { ...opts, port: Number(pgPort) };
            }
        } else if (typeof args[0] === 'number' && args[0] === DEFAULT_PG_NUM) {
            const host = typeof args[1] === 'string' ? args[1] : 'localhost';
            if (host === '127.0.0.1' || host === 'localhost') {
                args[0] = Number(pgPort);
            }
        }
        return origConnect.apply(this, args);
    };

    const origStringify = JSON.stringify;
    JSON.stringify = function (value, replacer, space) {
        if (value && typeof value === 'object') {
            const jobInputs = value.job_inputs;
            if (
                jobInputs &&
                (jobInputs.host === '127.0.0.1' || jobInputs.host === 'localhost') &&
                jobInputs.port === DEFAULT_PG &&
                jobInputs.dbname === 'posthog'
            ) {
                jobInputs.port = pgPort;
            }
            const payload = value.payload;
            if (
                payload &&
                (payload.host === '127.0.0.1' || payload.host === 'localhost') &&
                payload.port === DEFAULT_PG &&
                payload.database === 'posthog'
            ) {
                payload.port = pgPort;
            }
        }
        const json = origStringify.call(this, value, replacer, space);
        if (typeof json === 'string' && json.includes(DEFAULT_PG) && json.includes('posthog')) {
            return json.replace(singleQuotePortRe, `port: '${pgPort}'`).replace(doubleQuotePortRe, `"port":"${pgPort}"`);
        }
        return json;
    };
}

if (process.env.PLAYWRIGHT_RESULTS_DIR || process.env.BASE_URL) {
    const origLoad = Module._load;
    Module._load = function (request, parent, isMain) {
        const exported = origLoad.apply(this, arguments);
        if (
            request === '@playwright/test' &&
            exported &&
            typeof exported.defineConfig === 'function' &&
            !exported.defineConfig.__enactWrapped
        ) {
            const origDefineConfig = exported.defineConfig;
            const wrappedDefineConfig = function (cfg) {
                if (cfg && typeof cfg === 'object') {
                    if (process.env.BASE_URL) {
                        cfg.use = { ...cfg.use, baseURL: process.env.BASE_URL };
                    }
                    if (process.env.PLAYWRIGHT_RESULTS_DIR) {
                        const resultsDir = origResolve(process.env.PLAYWRIGHT_RESULTS_DIR);
                        cfg.outputDir = path.join(resultsDir, 'test-results');
                        cfg.snapshotDir = path.join(resultsDir, '__snapshots__');
                        if (Array.isArray(cfg.reporter)) {
                            cfg.reporter = cfg.reporter.map((entry) => {
                                if (!Array.isArray(entry)) return entry;
                                const [name, opts = {}] = entry;
                                if (name === 'html') {
                                    return [name, { ...opts, outputFolder: path.join(resultsDir, 'playwright-report') }];
                                }
                                if ((name === 'junit' || name === 'json') && opts.outputFile) {
                                    return [
                                        name,
                                        { ...opts, outputFile: path.join(resultsDir, path.basename(opts.outputFile)) },
                                    ];
                                }
                                return entry;
                            });
                        }
                    }
                }
                return origDefineConfig.call(this, cfg);
            };
            wrappedDefineConfig.__enactWrapped = true;
            try {
                exported.defineConfig = wrappedDefineConfig;
                if (exported.default && typeof exported.default === 'object') {
                    exported.default.defineConfig = wrappedDefineConfig;
                }
            } catch {
                return new Proxy(exported, {
                    get(target, prop, receiver) {
                        if (prop === 'defineConfig') return wrappedDefineConfig;
                        return Reflect.get(target, prop, receiver);
                    },
                });
            }
        }
        return exported;
    };
}

if (typeof Module.syncBuiltinESMExports === 'function') {
    Module.syncBuiltinESMExports();
}
