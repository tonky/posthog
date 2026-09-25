package env

// -------------------------------------------------------------
// Typed vocabulary for the environment-variable bundles
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
#LogLevelMode: #LogLevel.Error | #LogLevel.Warn | #LogLevel.Info | #LogLevel.Debug | #LogLevel.Trace | *#LogLevel.Info

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
#GoToolchainMode: #GoToolchain.Auto | #GoToolchain.Local | #GoToolchain.Path | *#GoToolchain.Auto

#CratesIoProtocol: {
	Sparse: "sparse"
	Git:    "git"
}
#CratesIoProtocolMode: #CratesIoProtocol.Sparse | #CratesIoProtocol.Git | *#CratesIoProtocol.Sparse
