package env

// -------------------------------------------------------------
// POSIX & Shell Standard Environment Schemas
// -------------------------------------------------------------

#PosixPager: {
	Less: "less"
	More: "more"
	Cat:  "cat"
}
#PosixPagerMode: #PosixPager.Less | #PosixPager.More | #PosixPager.Cat | *#PosixPager.Less

#PosixEditor: {
	Nano:  "nano"
	Vim:   "vim"
	Nvim:  "nvim"
	Helix: "helix"
	Emacs: "emacs"
	Code:  "code"
}
#PosixEditorMode: #PosixEditor.Nano | #PosixEditor.Vim | #PosixEditor.Nvim |
	#PosixEditor.Helix | #PosixEditor.Emacs | #PosixEditor.Code | *#PosixEditor.Nano

// A shell environment, not a language: there is no package to put in `tools:` and no
// version to pin, so it keeps the `Env` suffix that the language bundles dropped.
#PosixEnv: {
	PAGER?:   #PosixPagerMode
	EDITOR?:  #PosixEditorMode
	[string]: _
}
