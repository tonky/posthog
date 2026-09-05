package env

// -------------------------------------------------------------
// Core Type Definitions & SemVer Constraints
// -------------------------------------------------------------

// SemVer 2.0.0 compliant version constraint regex (e.g. "1.24", "1.23.1", "3.13.0-rc.1", "22")
#SemVer: string & =~"^[0-9]+(\\.[0-9]+)*(-[a-zA-Z0-9.]+)?(\\+[a-zA-Z0-9.]+)?$"

// -------------------------------------------------------------
// Language Environment Presets
// -------------------------------------------------------------

#GoDevPresets: {
	standard: #GoEnv & {
		CGO_ENABLED: 0
	}
	cgo: #GoEnv & {
		CGO_ENABLED: 1
	}
}

#RustDevPresets: {
	standard: #RustEnv & {
		RUST_BACKTRACE: 1
		RUST_LOG:       "info"
	}
	debug: #RustEnv & {
		RUST_BACKTRACE: "full"
		RUST_LOG:       "debug"
	}
}

#NodeDevPresets: {
	standard: #NodeEnv & {
		NODE_ENV: "development"
	}
	production: #NodeEnv & {
		NODE_ENV: "production"
	}
}

#PythonDevPresets: {
	standard: #PythonEnv & {
		PYTHONUNBUFFERED:        1
		PYTHONDONTWRITEBYTECODE: 1
	}
}

#RubyDevPresets: {
	standard: #RubyEnv & {
		RAILS_ENV: "development"
	}
	production: #RubyEnv & {
		RAILS_ENV: "production"
	}
}

#GleamDevPresets: {
	standard: #GleamEnv & {
		GLEAM_LOG:    "info"
		GLEAM_TARGET: "erlang"
	}
	js: #GleamEnv & {
		GLEAM_LOG:    "info"
		GLEAM_TARGET: "javascript"
	}
	debug: #GleamEnv & {
		GLEAM_LOG: "trace"
	}
}

#ErlangDevPresets: {
	standard: #ErlangEnv & {
		REBAR_COLOR: "always"
	}
}

#WasmBaseEnv: {
	CC?:                                          string | *"clang"
	CC_wasm32_unknown_unknown?:                   string | *"/nix/store/603yaax3l2jmc0hfv6g3hgjr1qk5jfxk-clang-21.1.8/bin/clang"
	CFLAGS_wasm32_unknown_unknown?:               string | *"-resource-dir=/nix/store/w021fbcg4z6vxihnp6gb6vijyifl051f-clang-wrapper-21.1.8/resource-root"
	CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER: string | *"gcc"
	[string]:                                     _
}

#WasmEnv: #WasmBaseEnv
