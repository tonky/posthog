package env

// -------------------------------------------------------------
// Erlang/OTP & BEAM Ecosystem Environment Schema (Strictly Typed)
// -------------------------------------------------------------

#RebarColor: {
	Always: "always"
	Auto:   "auto"
	None:   "none"
}
#RebarColorMode: #RebarColor.Always | #RebarColor.Auto | #RebarColor.None | *#RebarColor.Always

// Usage: env.#Erlang or env.#Erlang & { REBAR_COLOR: "always" }
// A version is data, and it belongs on the package: `tools: [pkgs.erlang & {version: "28"}]`.
#Erlang: {
	REBAR_COLOR?: #RebarColorMode
	ERL_LIBS?:    string
	MIX_PATH?:    string
	[string]:     _
}
