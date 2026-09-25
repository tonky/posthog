package env

// -------------------------------------------------------------
// Zig Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Zig or env.#Zig & { ZIG_LOCAL_CACHE_DIR: ".zig-cache" }
// A version is data, and it belongs on the package: `tools: [pkgs.zig & {version: "0.14.0"}]`.
#Zig: {
	ZIG_GLOBAL_CACHE_DIR?: string
	ZIG_LOCAL_CACHE_DIR?:  string
	[string]:              _
}
