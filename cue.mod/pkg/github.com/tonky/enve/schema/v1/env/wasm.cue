package env

// -------------------------------------------------------------
// WebAssembly Environment Schema
// -------------------------------------------------------------

// A cross-compilation target, not a language: there is no package to put in `tools:` and
// no version to pin, so it keeps the `Env` suffix that `#PosixEnv` uses.
#WasmEnv: {
	CC?:                                          string | *"clang"
	CC_wasm32_unknown_unknown?:                   string
	CFLAGS_wasm32_unknown_unknown?:               string
	CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER: string | *"gcc"
	[string]:                                     _
}
