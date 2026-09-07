package schema

import "github.com/tonky/enve/schema/v1/env:env"

#Version: "v2"

#Output: {
	path:      string
	hashAlgo?: string
	hash?:     string
}

#Port:             int & > 0 & <= 65535
#UnprivilegedPort: int & > 1024 & <= 65535

#BuildSpec: {
	pname:          string
	version:        string
	src:            string
	subPackages?:   _
	ldflags?:       _
	npmFlags?:      _
	nodeVersion?:   _
	packageJson?:   _
	packageLock?:   _
	buildScript?:   _
	format?:        _
	pythonVersion?: _
	features?:      _
	cargoFlags?:    _
	target?:        _
	erlangVersion?: _
	environment?:   _
	[string]:       _
}

#ServiceReadinessProbe: {
	port?:      #Port
	path?:      string
	command?:   string
	timeoutMs?: int & > 0 | *5000
}

#ServiceFile: {
	target?:  string
	content?: string
	source?:  string
	mode?:    string | *"0644"
}

#ServiceLifecycle: {
	init?:      [...string]
	preStart?:  [...string]
	postStart?: [...string]
}

#Service: {
	name?:           string
	image?:          string
	command?:        string
	build?:          #BuildSpec
	directory?:      string
	dataDir?:        string
	files?:          [string]: #ServiceFile | string
	lifecycle?:      #ServiceLifecycle
	port?:           #Port
	environment?:    [string]: _
	dependsOn?:      [...string]
	volumes?:        [...string]
	readinessProbe?: #ServiceReadinessProbe
}

#GitHooks: {
	cue_fmt?:       bool | *false
	clippy?:        bool | *false
	prettier?:      bool | *false
	ruff?:          bool | *false
	golangci_lint?: bool | *false
	custom?:        [string]: string
}

// v2 DevEnvironment mandates explicit schemaVersion identifier
#DevEnvironment: {
	schemaVersion: #Version | *"v2"
	name?:         string | *""
	build?:        #BuildSpec
	tools?:        [..._] | *[]
	runtimes?:     env.#RuntimeMap
	services?:     [string]: #Service
	ports?:        [...#Port]
	gitHooks?:     #GitHooks
	environment?:  [string]: _
	shellHook?:    string
}

#CueOnlyDevEnvironment: #DevEnvironment

// Canonical aliases
#Environment: #DevEnvironment
#Enve:        #DevEnvironment
