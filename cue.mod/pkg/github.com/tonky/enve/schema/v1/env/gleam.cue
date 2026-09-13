package env

// -------------------------------------------------------------
// Gleam Language Environment Schema (Strictly Typed)
// -------------------------------------------------------------

#GleamBaseEnv: {
	GLEAM_VERSION?: #SemVer | *"1.8"
	GLEAM_LOG?:     #LogLevelMode
	GLEAM_TARGET?:  #GleamTargetMode
	[string]:       _
}

// Gleam 1.8+ (Modern compiler with full Erlang & JS target support)
#Gleam1_8Env: #GleamBaseEnv & {
	GLEAM_TARGET: #GleamTarget.Erlang
}

// Parameterized Gleam Environment
// Usage: env.#Gleam or env.#Gleam & { GLEAM_VERSION: "1.8.1", GLEAM_LOG: "debug" }
#Gleam: #GleamBaseEnv & {
	GLEAM_VERSION?: #SemVer | *"1.8"
	GLEAM_LOG?:     #LogLevelMode
	GLEAM_TARGET?:  #GleamTargetMode
}

// Default Gleam environment alias
#GleamEnv: #Gleam
