package env

// -------------------------------------------------------------
// Ruby Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Ruby or env.#Ruby & { RAILS_ENV: "production" }
// A version is data, and it belongs on the package: `tools: [pkgs.ruby & {version: "3.3.1"}]`.
#Ruby: {
	RAILS_ENV?:        #AppEnvMode
	RUBY_YJIT_ENABLE?: 0 | 1 | *1
	[string]:          _
}
