package env

// -------------------------------------------------------------
// Gleam Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Gleam or env.#Gleam & { GLEAM_LOG: "debug" }
// A version is data, and it belongs on the package: `tools: [pkgs.gleam & {version: "1.8.1"}]`.
#Gleam: {
	GLEAM_LOG?:    #LogLevelMode
	GLEAM_TARGET?: #GleamTargetMode
	[string]:      _
}
