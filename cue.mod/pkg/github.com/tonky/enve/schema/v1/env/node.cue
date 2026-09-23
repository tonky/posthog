package env

// -------------------------------------------------------------
// Node / TypeScript Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Node or env.#Node & { NODE_ENV: "production" }
// A version is data, and it belongs on the package: `tools: [pkgs.nodejs & {version: "22"}]`.
#Node: {
	NODE_ENV?:            #AppEnvMode
	NPM_CONFIG_LOGLEVEL?: #NpmLogLevelMode
	[string]:             _
}
