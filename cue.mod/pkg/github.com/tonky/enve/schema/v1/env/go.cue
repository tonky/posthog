package env

// -------------------------------------------------------------
// Go Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Go or env.#Go & { CGO_ENABLED: 1 }
// A version is data, and it belongs on the package: `tools: [pkgs.go & {version: "1.24"}]`.
#Go: {
	CGO_ENABLED?: 0 | 1 | *0
	GO111MODULE?: #GoModuleMode
	GOTOOLCHAIN?: #GoToolchainMode
	[string]:     _
}
