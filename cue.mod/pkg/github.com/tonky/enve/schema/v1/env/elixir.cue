package env

// -------------------------------------------------------------
// Elixir Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Elixir or env.#Elixir & { MIX_ENV: "test" }
// A version is data, and it belongs on the package: `tools: [pkgs.elixir & {version: "1.18"}]`.
#Elixir: {
	MIX_ENV?:     #MixEnvMode
	HEX_OFFLINE?: 0 | 1 | *1
	ERL_AFLAGS?:  string
	[string]:     _
}
