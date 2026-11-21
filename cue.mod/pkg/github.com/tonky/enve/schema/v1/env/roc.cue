package env

// -------------------------------------------------------------
// Roc Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Roc or env.#Roc & { ROC_CACHE_DIR: ".roc" }
// A version is data, and it belongs on the package: `tools: [pkgs.roc & {version: "0.1.0"}]`.
#Roc: {
	ROC_CACHE_DIR?: string
	[string]:       _
}
