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

#ErlangBaseEnv: {
	REBAR_COLOR?: #RebarColorMode
	ERL_LIBS?:    string | *"/nix/store/2z8d9n31nwgll7cvb4pfxhijc2pl83m0-hex-2.5.1/lib/erlang/lib"
	MIX_PATH?:    string | *"/nix/store/2z8d9n31nwgll7cvb4pfxhijc2pl83m0-hex-2.5.1/lib/erlang/lib/hex/ebin"
	[string]:     _
}

// Parameterized Erlang Environment
#Erlang: #ErlangBaseEnv & {
	REBAR_COLOR?: #RebarColorMode
}

#Otp27BaseEnv: {
	REBAR_COLOR?: #RebarColorMode
	ERL_LIBS?:    string | *"/nix/store/r3d5mk7nwdllvrmzhpxbdzw0317bk72k-hex-2.5.1/lib/erlang/lib"
	MIX_PATH?:    string | *"/nix/store/r3d5mk7nwdllvrmzhpxbdzw0317bk72k-hex-2.5.1/lib/erlang/lib/hex/ebin"
	[string]:     _
}

#Otp27Env: #Otp27BaseEnv
#Otp28Env: #ErlangBaseEnv

// Default Erlang environment alias
#ErlangEnv: #Erlang
