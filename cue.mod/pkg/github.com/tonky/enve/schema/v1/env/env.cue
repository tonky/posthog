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

// -------------------------------------------------------------
// Declarative Runtime Specifications (for `#DevEnvironment.runtimes`)
// -------------------------------------------------------------

#AppEnv: {
	Development: "development"
	Production:  "production"
	Test:        "test"
}
#AppEnvMode: #AppEnv.Development | #AppEnv.Production | #AppEnv.Test | *#AppEnv.Development

#MixEnv: {
	Dev:  "dev"
	Test: "test"
	Prod: "prod"
}
#MixEnvMode: #MixEnv.Dev | #MixEnv.Test | #MixEnv.Prod | *#MixEnv.Dev

#LogLevel: {
	Error: "error"
	Warn:  "warn"
	Info:  "info"
	Debug: "debug"
	Trace: "trace"
}
#LogLevelMode: #LogLevel.Error | #LogLevel.Warn | #LogLevel.Info | #LogLevel.Debug | #LogLevel.Trace | string | *#LogLevel.Info

#NpmLogLevel: {
	Silent:  "silent"
	Error:   "error"
	Warn:    "warn"
	Info:    "info"
	Verbose: "verbose"
}
#NpmLogLevelMode: #NpmLogLevel.Silent | #NpmLogLevel.Error | #NpmLogLevel.Warn | #NpmLogLevel.Info | #NpmLogLevel.Verbose | *#NpmLogLevel.Warn

#ColorMode: {
	Always: "always"
	Auto:   "auto"
	Never:  "never"
}
#ColorModeSetting: #ColorMode.Always | #ColorMode.Auto | #ColorMode.Never | *#ColorMode.Always

#GleamTarget: {
	Erlang:     "erlang"
	JavaScript: "javascript"
}
#GleamTargetMode: #GleamTarget.Erlang | #GleamTarget.JavaScript | *#GleamTarget.Erlang

#GoModule: {
	On:   "on"
	Off:  "off"
	Auto: "auto"
}
#GoModuleMode: #GoModule.On | #GoModule.Off | #GoModule.Auto | *#GoModule.On

#GoToolchain: {
	Auto:  "auto"
	Local: "local"
	Path:  "path"
}
#GoToolchainMode: #GoToolchain.Auto | #GoToolchain.Local | #GoToolchain.Path | string | *#GoToolchain.Auto

#CratesIoProtocol: {
	Sparse: "sparse"
	Git:    "git"
}
#CratesIoProtocolMode: #CratesIoProtocol.Sparse | #CratesIoProtocol.Git | *#CratesIoProtocol.Sparse

#GoRuntimeSpec: {
	version?:     #SemVer | *"1.24"
	cgo?:         bool | 0 | 1 | *0
	toolchain?:   #GoToolchainMode
	experiments?: [...string] | string
	[string]:     _
}

#RustRuntimeSpec: {
	version?:   #SemVer | *"1.98.0"
	backtrace?: bool | 0 | 1 | "full" | *1
	log?:       #LogLevelMode
	color?:     #ColorModeSetting
	[string]:   _
}

#NodeRuntimeSpec: {
	version?:  #SemVer | *"22"
	env?:      #AppEnvMode
	logLevel?: #NpmLogLevelMode
	[string]:  _
}

#PythonRuntimeSpec: {
	version?:           #SemVer | *"3.13"
	unbuffered?:        bool | 0 | 1 | *1
	dontWriteBytecode?: bool | 0 | 1 | *1
	[string]:           _
}

#RubyRuntimeSpec: {
	version?: #SemVer | *"3.4"
	env?:     #AppEnvMode
	[string]: _
}

#GleamRuntimeSpec: {
	version?: #SemVer | *"1.8"
	target?:  #GleamTargetMode
	log?:     #LogLevelMode
	[string]: _
}

#ErlangRuntimeSpec: {
	version?:    #SemVer | *"27"
	rebarColor?: #ColorModeSetting
	[string]:    _
}

#ZigRuntimeSpec: {
	version?:        #SemVer | *"0.14"
	globalCacheDir?: string
	localCacheDir?:  string
	[string]:        _
}

#RocRuntimeSpec: {
	version?:  #SemVer | *"0.1"
	cacheDir?: string
	[string]:  _
}

#ElixirRuntimeSpec: {
	version?:    #SemVer | *"1.18"
	mixEnv?:     #MixEnvMode
	hexOffline?: bool | 0 | 1 | *1
	[string]:    _
}

#RuntimeMap: {
	go?:     #GoRuntimeSpec
	rust?:   #RustRuntimeSpec
	node?:   #NodeRuntimeSpec
	python?: #PythonRuntimeSpec
	ruby?:   #RubyRuntimeSpec
	gleam?:  #GleamRuntimeSpec
	erlang?: #ErlangRuntimeSpec
	zig?:    #ZigRuntimeSpec
	roc?:    #RocRuntimeSpec
	elixir?: #ElixirRuntimeSpec
	[string]: _
}
