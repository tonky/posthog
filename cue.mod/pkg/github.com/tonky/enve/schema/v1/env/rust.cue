package env

// -------------------------------------------------------------
// Rust Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Rust or env.#Rust & { RUST_LOG: "debug" }
// A version is data, and it belongs on the package: `tools: [pkgs.rustc & {version: "1.98"}]`.
#Rust: {
	RUST_BACKTRACE?:                      0 | 1 | "full" | *1
	RUST_LOG?:                            #LogLevelMode
	CARGO_TERM_COLOR?:                    #ColorModeSetting
	CARGO_REGISTRIES_CRATES_IO_PROTOCOL?: #CratesIoProtocolMode
	[string]:                             _
}
