package env

// -------------------------------------------------------------
// POSIX & Shell Standard Environment Schemas
// -------------------------------------------------------------

#PosixPager: {
	Less: "less"
	More: "more"
	Cat:  "cat"
}
#PosixPagerMode: #PosixPager.Less | #PosixPager.More | #PosixPager.Cat | string | *#PosixPager.Less

#PosixEditor: {
	Nano:  "nano"
	Vim:   "vim"
	Nvim:  "nvim"
	Helix: "helix"
	Emacs: "emacs"
	Code:  "code"
}
#PosixEditorMode: #PosixEditor.Nano | #PosixEditor.Vim | #PosixEditor.Nvim |
	#PosixEditor.Helix | #PosixEditor.Emacs | #PosixEditor.Code | string | *#PosixEditor.Nano

#PosixEnv: {
	PAGER?:   #PosixPagerMode
	EDITOR?:  #PosixEditorMode
	[string]: _
}

// Parameterized POSIX environment alias
#Posix: #PosixEnv
