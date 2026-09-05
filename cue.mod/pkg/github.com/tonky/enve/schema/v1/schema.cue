package schema

#Output: {
	path:      string
	hashAlgo?: string
	hash?:     string
}

#Port:             int & > 0 & <= 65535
#UnprivilegedPort: int & > 1024 & <= 65535

#Derivation: {
	pname:   string
	version: string
	name:    "\(pname)-\(version)"
	builder: string
	args?: [...string]
	env?: [string]: _
	inputDrvs?: [string]: _
	outputs: [string]: #Output
}

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

#PackageRef: string | {
	pname:    string
	version?: string
}

#ServiceReadinessProbe: {
	port?:      #Port
	path?:      string
	command?:   string
	timeoutMs?: int & > 0 | *5000
}

#Service: {
	name?:           string
	image?:          string
	command?:        string
	build?:          #BuildSpec
	directory?:      string
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

#DevEnvironment: {
	name?:        string | *""
	build?:       #BuildSpec
	tools?:       [..._] | *[]
	runtimes?:    [string]: _
	services?:    [string]: #Service
	ports?:       [...#Port]
	gitHooks?:    #GitHooks
	environment?: [string]: _
	shellHook?:   string
}

#CueOnlyDevEnvironment: {
	name?:        string | *""
	build?:       #BuildSpec
	tools?:       [..._] | *[]
	runtimes?:    [string]: _
	services?:    [string]: #Service
	ports?:       [...#Port]
	gitHooks?:    #GitHooks
	environment?: [string]: _
	shellHook?:   string
}

#GoBuildSpec: #BuildSpec
#NodeBuildSpec: #BuildSpec
#PythonBuildSpec: #BuildSpec
#RustBuildSpec: #BuildSpec
#GleamBuildSpec: #BuildSpec
#ErlangBuildSpec: #BuildSpec

// Canonical aliases
#Environment: #DevEnvironment
#Enve:        #DevEnvironment

