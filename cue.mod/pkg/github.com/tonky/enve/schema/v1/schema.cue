package schema

import (
	"net"
	"strings"
	"time"
)

// A bare number in a duration position, admitted by the type only so `enve` can refuse
// it by name. CUE reads an integer there as nanoseconds and every millisecond field
// removed in 0.12 read it as milliseconds, so nothing in the file says which. Left to
// `time.Duration` alone it fails as `bound target type mismatch for int`, naming
// neither the field nor the fix; the loader names both and prints the duration to write
// instead (see `crates/enve-cue/src/model/durations.rs`). Deleted at 1.0 with `#Removed`.
#Unitless: number

// A duration says its own unit: "800ms", "3s", "1m30s". `time.Duration` accepts a
// negative one, which no field here means, so the sign is ruled out where the type is
// declared rather than in every field that uses it. Zero-versus-positive is a
// per-field rule and lives in the deserializer.
#Duration: time.Duration & !~"^-" | #Unitless
#Host:     net.IP | string

// A field removed in 0.12, declared only so `enve` can refuse it by name and print the
// replacement (see `crates/enve-cue/src/model/durations.rs`). Without the declaration a
// closed struct fails at unification, naming neither the field nor the fix, and an open
// struct accepts the field and silently ignores the budget it declares. Deleted at 1.0.
#Removed: _

#Output: {
	path:      string
	hashAlgo?: string
	hash?:     string
}

#Port:             int & >0 & <=65535
#UnprivilegedPort: int & >1024 & <=65535

// SemVer 2.0.0 compliant version constraint (e.g. "1.24", "1.23.1", "3.13.0-rc.1", "22").
#SemVer: string & =~"^[0-9]+(\\.[0-9]+)*(-[a-zA-Z0-9.]+)?(\\+[a-zA-Z0-9.]+)?$"

// Retired revision-selection declarations remain permissive for migration diagnostics.
#NixpkgsRev: #Removed
#Nixpkgs:    #Removed

#Derivation: {
	pname:   string
	version: string
	name:    "\(pname)-\(version)"
	builder: string
	args?: [...string]
	env?: [string]:       _
	inputDrvs?: [string]: _
	outputs: [string]:    #Output
	sandbox?: #BuildSandbox
}

#BuildIsolation: {
	Auto:     "auto"
	Required: "required"
}
#BuildIsolationMode: #BuildIsolation.Auto | #BuildIsolation.Required
#BuildSandbox: *close({
	isolation: #BuildIsolation.Auto
	readOnly: []
}) | close({
	isolation: #BuildIsolation.Required
	readOnly: [...string] | *[]
})
// Canonical Namespaced Enum Object for platforms & operating system families
#Platform: {
	// Exact Nix system target triplets
	X86_64Linux:   "x86_64-linux"
	Aarch64Linux:  "aarch64-linux"
	X86_64Darwin:  "x86_64-darwin"
	Aarch64Darwin: "aarch64-darwin"
	Riscv64Linux:  "riscv64-linux"

	// Operating system family scopes
	Linux:  "linux"
	Darwin: "darwin"
}

// Strongly-typed platform scope constraint
#PlatformScope: #Platform.X86_64Linux |
	#Platform.Aarch64Linux |
	#Platform.X86_64Darwin |
	#Platform.Aarch64Darwin |
	#Platform.Riscv64Linux |
	#Platform.Linux |
	#Platform.Darwin

// A canonical Nix package identifier (e.g. "ripgrep", "bat", "postgresql_16", "vchord").
#NixPackageName: string & =~"^[a-zA-Z0-9_.-]+$"

// A Nix attribute path inside nixpkgs (e.g. "go_1_24", "legacyPackages.x86_64-linux.ripgrep").
#NixAttribute: string & =~"^[a-zA-Z0-9_.-]+$"

// A remote HTTP or HTTPS download URL for source archives or binaries.
#HttpUrl: string & =~"^https?://.+"

// A filesystem path (relative to project root or absolute).
#FilePath: string

// A source location: either a remote HTTP URL or a local filesystem path.
#SourceLocation: #HttpUrl | #FilePath

// A platform-discriminated mapping of source locations.
#PlatformSourceMap: {
	"x86_64-linux"?:   #SourceLocation
	"aarch64-linux"?:  #SourceLocation
	"x86_64-darwin"?:  #SourceLocation
	"aarch64-darwin"?: #SourceLocation
}

// A source specification: either a single source location or a platform-specific map.
#SourceSpec: #SourceLocation | #PlatformSourceMap

// 64-character hexadecimal SHA-256 integrity hash.
#Sha256Hex: string & =~"^[0-9a-fA-F]{64}$"

// Nix or W3C SRI format hash (e.g. "sha256-AAAA...", "sha512-BBBB...").
#SriHash: string & =~"^sha(256|512)-[A-Za-z0-9+/=]+$"

// Cryptographic checksum digest (hex or SRI format).
#Checksum: #Sha256Hex | #SriHash

// A platform-discriminated mapping of checksum digests.
#PlatformHashMap: {
	"x86_64-linux"?:   #Checksum
	"aarch64-linux"?:  #Checksum
	"x86_64-darwin"?:  #Checksum
	"aarch64-darwin"?: #Checksum
}

// An integrity hash specification: either a single checksum or a platform-specific map.
#HashSpec: #Checksum | #PlatformHashMap

// A platform-discriminated mapping of remote URLs.
#PlatformUrlMap: {
	"x86_64-linux"?:   #HttpUrl
	"aarch64-linux"?:  #HttpUrl
	"x86_64-darwin"?:  #HttpUrl
	"aarch64-darwin"?: #HttpUrl
}

// A fixed-output remote resource fetch specification with cryptographic integrity hash.
// Like `src`/`sha256`, the URL and its hash are one value or a platform map; a platform the
// URL map leaves out has no such resource.
#FetchSpec: {
	url:     #HttpUrl | #PlatformUrlMap
	hash?:   #HashSpec
	sha256?: #HashSpec
}

// Shell script commands executed during a build or install phase.
#ShellScript: string

// Path or name of an executable builder (e.g. "/bin/sh", "bash").
#ExecutablePath: string

// Command-line argument passed to a builder.
#CommandArgument: string

// Go package import path or directory (e.g. ".", "./cmd/server", "github.com/org/repo").
#GoPackagePath: string

// Go linker flag passed to `go build -ldflags` (e.g. "-X main.version=1.0.0", "-s -w").
#GoLdFlag: string

// Cargo command-line flag passed to `cargo build` (e.g. "-Z", "--offline").
#CargoFlag: string

// Cargo feature name (e.g. "postgres", "simd", "default").
#CargoFeature: string

// NPM/PNPM command-line flag (e.g. "--frozen-lockfile", "--legacy-peer-deps").
#NpmFlag: string

// Package feature flags: either a list of feature names or a map of feature toggle booleans.
#PackageFeatures: [...string] | {[string]: bool}

// A package resolved directly from the Nixpkgs universe.
#NixPackage: {
	pname:      #NixPackageName
	attr?:      #NixAttribute
	version?:   #SemVer
	rev?:       #Removed
	features?:  #PackageFeatures
	libraries?: bool
}

// A strongly-typed package or build specification in enve.
// Unifies package declaration, source specification, and build toolchain flags.
#PackageSpec: {
	pname:     #NixPackageName
	attr?:     #NixAttribute
	version?:  #SemVer
	rev?:      #Removed
	features?: #PackageFeatures
	platforms?: [...#PlatformScope]
	// Programs in the environment load this package's shared libraries by name (python-magic
	// dlopens `file`'s libmagic, pyvips libvips): its own libs, and those of the outputs a
	// dev output propagates, join the loader path (LD_LIBRARY_PATH on Linux,
	// DYLD_FALLBACK_LIBRARY_PATH on macOS). Never its dependencies'. Without it a package is
	// only linked against (LIBRARY_PATH, and LD_RUN_PATH on Linux): on LD_LIBRARY_PATH it
	// would shadow the host's library of the same soname for every host binary.
	libraries?: bool

	// Source & Integrity
	src?:     #SourceSpec
	sha256?:  #HashSpec
	sandbox?: #BuildSandbox
	inputs?: [...#PackageRef]
	buildInputs?: [...#PackageRef]
	fetch?: [string]: #FetchSpec
	installPhase?: #ShellScript
	buildScript?:  #ShellScript
	builder?:      #ExecutablePath
	args?: [...#CommandArgument]
	exports?: [string]: string

	// Language Presets & Flags
	subPackages?: #GoPackagePath | [...#GoPackagePath]
	ldflags?: #GoLdFlag | [...#GoLdFlag]
	cgo?:       0 | 1
	goVersion?: #SemVer
	cargoFlags?: [...#CargoFlag]
	packageJson?: #FilePath
	packageLock?: #FilePath
	nodeVersion?: #SemVer
	npmFlags?: [...#NpmFlag]
	format?:        #PythonPackageFormatMode
	pythonVersion?: #SemVer
	target?:        string
	erlangVersion?: #SemVer

	environment?: [string]: _
}

// A custom package build specification: requires explicit source and semver.
#BuildSpec: #PackageSpec & {
	src:     #SourceSpec
	version: #SemVer
}

// Prebuilt binary release archives (e.g. GitHub release tarballs, zips, debs)
#ArchiveBuildSpec: #BuildSpec & {
	installPhase?: #ShellScript
}

// Go application compilation specification
#GoBuildSpec: #BuildSpec & {
	subPackages?: #GoPackagePath | [...#GoPackagePath] | *"."
	ldflags?: #GoLdFlag | [...#GoLdFlag]
	cgo?: 0 | 1 | *0
}

// Rust / Cargo compilation specification
#RustBuildSpec: #BuildSpec & {
	cargoFlags?: [...#CargoFlag] | *[]
	features?: [...#CargoFeature] | *[]
	release?: bool | *true
}

// Node.js application build specification
#NodeBuildSpec: #BuildSpec & {
	buildScript?: #ShellScript | *"build"
	packageJson?: #FilePath | *"package.json"
}

// Python package build specification
#PythonBuildSpec: #BuildSpec & {
	format?: #PythonPackageFormatMode
}

// Gleam application build specification
#GleamBuildSpec: #BuildSpec

// Erlang application build specification
#ErlangBuildSpec: #BuildSpec

// Custom / Generic shell build specification
#GenericBuildSpec: #BuildSpec & {
	builder?: #ExecutablePath | *"/bin/sh"
	args?: [...#CommandArgument]
	buildScript?: #ShellScript
}

// A package declaration in `tools:` or service dependencies.
// Can be a standard Nix package name string (#NixPackageName) or a strongly-typed #PackageSpec.
#PackageRef: #NixPackageName | #PackageSpec

// Liveness of a running service. `retries` failed probes in a row (Docker's
// `retries`, a Kubernetes `failureThreshold`) restart it; a passing probe resets the
// count. A probe that runs past `timeout` (default 10s) is one failure. The probe is
// `command`, else `path` (HTTP, any status below 500 passes), else `port`; a check that
// declares none of them (or no healthCheck at all) probes with the `readinessProbe`,
// which must therefore be cheap and idempotent, and only then connects to the port. A
// bare TCP connect passes against a hung server (its kernel still accepts into the
// backlog): `enve services --json` flags it as `liveness.probe: "tcp"`.
#ServiceHealthCheck: {
	port?:     #Port
	path?:     string
	command?:  string
	interval?: #Duration
	timeout?:  #Duration
	retries?:  int & >0 | *3

	intervalMs?: #Removed
	timeoutMs?:  #Removed
}

#ServiceReadinessProbe: {
	port?:         #Port
	path?:         string
	command?:      string
	initialDelay?: #Duration
	timeout?:      #Duration

	initialDelayMs?: #Removed
	timeoutMs?:      #Removed
}

#ServiceFile: {
	target?:  string
	content?: string
	source?:  string
	mode?:    string | *"0644"
}

// A hook is one command, a list of them, or a list with a deadline. A hook that runs
// past its budget is killed with its descendants, the way a probe already is; without
// one, an `init` that never returns hangs the whole environment with no message.
#HookSpec: {
	run: string | [...string]
	// Overrides `lifecycle.timeout` for this hook alone.
	timeout?: #Duration
}

#LifecycleHook: string | [...string] | #HookSpec

#ServiceLifecycle: {
	// The budget every hook in this block runs under unless it declares its own. Left
	// out, enve applies a built-in 30s — generous, because the point is that there is a
	// deadline at all, not that it is tight.
	timeout?:   #Duration
	init?:      #LifecycleHook
	postInit?:  #LifecycleHook
	preStart?:  #LifecycleHook
	postSpawn?: #LifecycleHook
	postStart?: #LifecycleHook
	preStop?:   #LifecycleHook
	postStop?:  #LifecycleHook
	onReload?:  #LifecycleHook
	seed?:      #LifecycleHook
}

#ServiceActionSpec: {
	run: string | [...string]
	timeout?: #Duration
	withServices?: bool | [...#DependencyRef | string] | *true
	env?: [string]:         _
	environment?: [string]: _
}

#ServiceAction: string | [...string] | #ServiceActionSpec

#ServiceResources: {
	cpu?:        string | float | int
	ram?:        string | float | int
	cpuPercent?: float | int
	ramMb?:      float | int
	startup?:    #Duration
	health?:     #Duration
	readiness?:  #Duration
	[string]:    _
}

#RestartPolicy: {
	Always:    "always"
	OnFailure: "on-failure"
	Never:     "never"
}
#RestartPolicyMode: #RestartPolicy.Always | #RestartPolicy.OnFailure | #RestartPolicy.Never | *#RestartPolicy.OnFailure

#ServiceIsolation: {
	Host:      "host"
	Netns:     "netns"
	Ephemeral: "ephemeral"
	Auto:      "auto"
}
#ServiceIsolationMode: #ServiceIsolation.Host | #ServiceIsolation.Netns | #ServiceIsolation.Ephemeral | *#ServiceIsolation.Auto

#PythonPackageFormat: {
	Pyproject:  "pyproject"
	Wheel:      "wheel"
	Setuptools: "setuptools"
}
#PythonPackageFormatMode: #PythonPackageFormat.Pyproject | #PythonPackageFormat.Wheel | #PythonPackageFormat.Setuptools | *#PythonPackageFormat.Pyproject

#PathMode: {
	Prepend: "prepend"
	Append:  "append"
}
#PathModeType: #PathMode.Prepend | #PathMode.Append

#AppEnv: {
	Development: "development"
	Production:  "production"
	Test:        "test"
}
#AppEnvMode: #AppEnv.Development | #AppEnv.Production | #AppEnv.Test | *#AppEnv.Development

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

#GoToolchain: {
	Auto:  "auto"
	Local: "local"
	Path:  "path"
}
#GoToolchainMode: #GoToolchain.Auto | #GoToolchain.Local | #GoToolchain.Path | *#GoToolchain.Auto

#GoModule: {
	On:   "on"
	Off:  "off"
	Auto: "auto"
}
#GoModuleMode: #GoModule.On | #GoModule.Off | #GoModule.Auto | *#GoModule.On

#CratesIoProtocol: {
	Sparse: "sparse"
	Git:    "git"
}
#CratesIoProtocolMode: #CratesIoProtocol.Sparse | #CratesIoProtocol.Git | *#CratesIoProtocol.Sparse

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

#DependencyCondition: {
	Ready:   "ready"
	Healthy: "healthy"
	Started: "started"
}
#DependencyConditionMode: #DependencyCondition.Ready |
	#DependencyCondition.Healthy |
	#DependencyCondition.Started |
	*#DependencyCondition.Ready

#ServiceDependency: {
	service:    #Service
	condition?: #DependencyConditionMode
	timeout?:   #Duration

	timeoutMs?: #Removed
	enabled?:   bool | *true
}

#DependencyRef: *#ServiceDependency | #Service

#ServiceDependencyMap: [string]: #ServiceDependency | bool | {
	service:    #Service
	condition?: #DependencyConditionMode
	timeout?:   #Duration

	timeoutMs?: #Removed
	enabled?:   bool | *true
}

// Environment restriction is opt-in and applies to native service children.
#ServiceEnvironmentMode: {
	Inherit:    "inherit"
	Restricted: "restricted"
}
#ServiceEnvironmentPolicy: close({
	mode: #ServiceEnvironmentMode.Inherit
}) | close({
	mode: #ServiceEnvironmentMode.Restricted
	forward?: [...string & =~"^[A-Za-z_][A-Za-z0-9_]*$"]
})

#Service: {
	// Marks a service for the loader, which records the directory it was
	// declared in as `originDir`. Hidden, so it is never exported.
	_enveService: true
	name?:        string
	enabled?:     bool | *true
	external?:    bool | *false
	host?:        #Host | *"127.0.0.1"
	url?:         string
	package?:     #PackageRef
	packages?: [...#PackageRef]
	// Packages the server loads. A postgres service runs its `package` joined with them
	// into one tree (nixpkgs' `postgresql.withPackages`), which replaces that server in
	// the profile's tools; each extension lays out `lib/<module>` and
	// `share/postgresql/extension/`, as nixpkgs' extensions do. Elsewhere they are
	// further `packages`.
	extensions?: [...#PackageRef]
	image?:     string
	command?:   string
	build?:     #BuildSpec
	directory?: string | *"."
	originDir?: string
	watch?: [...string]
	dataDir?: string
	files?: [string]: #ServiceFile | string
	lifecycle?:      #ServiceLifecycle
	port?:           #Port
	controllerPort?: #Port
	// Further listeners by key; each is a port slot as `port` is (named instances
	// allocate each one: `$PORT_<KEY>`, `${ENVE_SERVICE_<NAME>_PORT_<KEY>}`).
	ports?: [=~"^[a-z][a-z0-9_]*$"]: #Port
	timeout?: #Duration
	// Startup grace (Compose's start_period): probe failures this long after spawn
	// do not count, so probes retry until they pass or this and `timeout` run out.
	startPeriod?: #Duration
	// How long the service gets between SIGTERM and SIGKILL when it is stopped,
	// after its preStop hook (systemd's TimeoutStopSec). Default 10s.
	stopGrace?:         #Duration
	environmentPolicy?: #ServiceEnvironmentPolicy
	environment?: [string]: _
	test?: #ServiceAction
	lint?: #ServiceAction
	tasks?: [string]: #ServiceAction
	// `string` is accepted by the schema only so that enve can refuse it with a message
	// naming the service and the replacement; see model/depends_on.rs. It stays: a
	// dependency written as a name is what every compose-shaped schema teaches.
	dependsOn?: [...#DependencyRef | string] | #ServiceDependencyMap
	volumes?: [...string]
	healthCheck?:    #ServiceHealthCheck
	readinessProbe?: #ServiceReadinessProbe
	restartPolicy?:  #RestartPolicyMode
	// Restarts in a row a lost service gets before the run fails with a crash loop
	// (Compose's `max_attempts`); a passing health check resets the count. Default 3.
	maxRestarts?: int & >0
	isolation?:   #ServiceIsolationMode
	resources?:   #ServiceResources
	[string]:     _
}

#ExternalService: #Service & {
	external: true
	host:     #Host
}

#GitHooks: {
	cue_fmt?:       bool | *false
	clippy?:        bool | *false
	prettier?:      bool | *false
	ruff?:          bool | *false
	golangci_lint?: bool | *false
	custom?: [string]: string
}

// Service presets. Every default command, probe and environment value names the
// instance's ports and directories as the runner sets them, never `\(port)` or
// `\(dataDir)`: `$PORT`, `$PORT_<KEY>`, `$DATA_DIR` and `$SOCKET_DIR` are expanded when
// the service starts (in commands and probes by the shell, in the service's own
// `environment` values by the runner), so a named instance
// (`enve up --instance`) runs and probes on its own ports and data. The default
// instance's are the declared ones. HTTP probe paths are relative (`/ping`): the
// probe's `port` follows the slot. Extra listeners are `ports.<key>` slots.
//
// Every preset's `healthCheck` speaks its server's protocol (its own client, or HTTP)
// within 5s: a TCP connect passes against a hung or stopped server, whose kernel still
// completes the handshake. A server answers in milliseconds; a hung one fails well inside
// the check's interval (10s), so `retries` failures take `retries` intervals.
//
// No preset defaults `dataDir`: CUE cannot see the key a service is declared under, so
// a default here would put every service of a kind in one directory (two
// `#PostgresService`s sharing one cluster). enve defaults it to `.enve/data/<key>`
// (`.enve/instances/<id>/data/<key>` in a named instance) where the key is known.
#PostgresService: #Service & {
	package: #PackageRef | *"postgresql"

	let defaultPort = 5432
	let defaultDb = "postgres"
	let defaultUser = "postgres"
	let defaultTimeout = "2500ms"

	port: #Port | *defaultPort
	// With the data, not in `/tmp`: a socket left behind by a crashed postmaster
	// otherwise blocks the next start of an unrelated project on the same port, which
	// is what the supervisor's stale-socket sweep exists to paper over.
	socketDir: string | *"$SOCKET_DIR"
	database:  string | *defaultDb
	user:      string | *defaultUser
	timeout:   #Duration | *defaultTimeout
	command:   string | *"postgres -D \"$DATA_DIR\" -k \"\(socketDir)\" -p $PORT"
	// `user` and `database` are any names postgres takes: quoted for the shell in every
	// command and probe, and percent-encoded in the URL. `initdb` creates `user` as the
	// bootstrap superuser of a new cluster; on every start, between the health check and
	// the readiness probe, enve creates whichever of the two the running cluster lacks (a
	// data directory an older enve or another config initialised), and never alters one
	// that exists.
	let shUser = _#ShellQuoted & {raw: user}
	let shDatabase = _#ShellQuoted & {raw: database}
	let urlUser = _#URLComponent & {raw: user}
	let urlDatabase = _#URLComponent & {raw: database}
	lifecycle: {
		init: *["initdb -D \"$DATA_DIR\" -U \(shUser.out) --auth-local=trust --auth-host=trust --locale=C --encoding=UTF8"] | #LifecycleHook
		// Postgres runs its checkpointer and walwriter as child processes, so the group
		// SIGTERM that stops every other service reaches them directly and the postmaster
		// reads that as a crash rather than a shutdown. Without this it never checkpoints,
		// and every later boot pays for an automatic recovery.
		preStop: *["pg_ctl stop -D \"$DATA_DIR\" -m fast"] | #LifecycleHook
	}
	environment: {
		PGDATA:       "$DATA_DIR"
		PGPORT:       "$PORT"
		PGHOST:       socketDir
		PGUSER:       user
		DATABASE_URL: "postgresql://\(urlUser.out)@127.0.0.1:$PORT/\(urlDatabase.out)"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		command: string | *"pg_isready -h 127.0.0.1 -p $PORT -U \(shUser.out) -d \(shDatabase.out)"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"psql -h 127.0.0.1 -p $PORT -U \(shUser.out) -d \(shDatabase.out) -c 'SELECT 1;'"
		timeout: #Duration | *defaultTimeout
	}
}

#RedisService: #Service & {
	package: #PackageRef | *"redis"

	let defaultPort = 6379
	let defaultTimeout = "1500ms"

	port:    #Port | *defaultPort
	timeout: #Duration | *defaultTimeout
	command: string | *"redis-server --port $PORT --dir \"$DATA_DIR\" --daemonize no"
	environment: {
		REDIS_PORT: "$PORT"
		REDIS_URL:  "redis://localhost:$PORT/0"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		command: string | *"redis-cli -p $PORT ping"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"redis-cli -p $PORT ping"
		timeout: #Duration | *defaultTimeout
	}
}

#ValkeyService: #Service & {
	package: #PackageRef | *"valkey"

	let defaultPort = 6379
	let defaultTimeout = "1500ms"

	port:    #Port | *defaultPort
	timeout: #Duration | *defaultTimeout
	command: string | *"valkey-server --port $PORT --dir \"$DATA_DIR\" --daemonize no"
	// Valkey answers the Redis protocol, so its clients read the Redis variables.
	environment: {
		REDIS_PORT: "$PORT"
		REDIS_URL:  "redis://localhost:$PORT/0"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		command: string | *"valkey-cli -p $PORT ping"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"valkey-cli -p $PORT ping"
		timeout: #Duration | *defaultTimeout
	}
}

#MySQLService: #Service & {
	package: #PackageRef | *"mysql"

	let defaultPort = 3306
	let defaultTimeout = "3500ms"

	port:    #Port | *defaultPort
	timeout: #Duration | *defaultTimeout
	lifecycle: {
		init: *["mysqld --no-defaults --initialize-insecure --datadir=\"$DATA_DIR\" --tmpdir=\"$TMP_DIR\""] | #LifecycleHook
	}
	// Every path the instance's own: the socket and the pid file both default into a
	// shared location (`/tmp/mysql.sock`), which a second instance would take from the
	// first, and the temp dir (`$TMPDIR`), whose `#sql*` files every start deletes.
	// `--mysqlx=OFF` closes the X protocol listener, whose own default port (33060) is
	// not the one this service was given.
	command: string | *"mysqld --no-defaults --datadir=\"$DATA_DIR\" --tmpdir=\"$TMP_DIR\" --port=$PORT --socket=\"$SOCKET_DIR/mysql.sock\" --pid-file=\"$DATA_DIR/mysqld.pid\" --mysqlx=OFF --bind-address=127.0.0.1"
	environment: {
		MYSQL_TCP_PORT: "$PORT"
	}
	let servicePort = port

	// `ping` exits 0 for any server that answers, an access denied included.
	healthCheck: {
		port:    #Port | *servicePort
		command: string | *"mysqladmin ping -h 127.0.0.1 -P $PORT -u root"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"mysqladmin ping -h 127.0.0.1 -P $PORT -u root"
		timeout: #Duration | *defaultTimeout
	}
}

#MariaDBService: #Service & {
	package: #PackageRef | *"mariadb"

	let defaultPort = 3306
	let defaultTimeout = "3500ms"

	port:    #Port | *defaultPort
	timeout: #Duration | *defaultTimeout
	lifecycle: {
		init: *["mariadb-install-db --no-defaults --datadir=\"$DATA_DIR\" --auth-root-authentication-method=normal"] | #LifecycleHook
	}
	// `mariadb-install-db` reads the temp dir from `TMPDIR`, which enve sets to `$TMP_DIR`.
	command: string | *"mariadbd --no-defaults --datadir=\"$DATA_DIR\" --tmpdir=\"$TMP_DIR\" --port=$PORT --socket=\"$SOCKET_DIR/mysql.sock\" --pid-file=\"$DATA_DIR/mariadbd.pid\" --bind-address=127.0.0.1"
	environment: {
		MYSQL_TCP_PORT: "$PORT"
		MARIADB_PORT:   "$PORT"
	}
	let servicePort = port

	// `ping` exits 0 for any server that answers, an access denied included.
	healthCheck: {
		port:    #Port | *servicePort
		command: string | *"mariadb-admin ping -h 127.0.0.1 -P $PORT -u root"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"mariadb-admin ping -h 127.0.0.1 -P $PORT -u root"
		timeout: #Duration | *defaultTimeout
	}
}

#ClickHouseService: #Service & {
	package: #PackageRef | *"clickhouse"

	let defaultHttpPort = 8123
	let defaultTcpPort = 9000
	let defaultTimeout = "3500ms"

	port: #Port | *defaultHttpPort
	// The native protocol: a port slot of its own (`$PORT_NATIVE`), so a named instance
	// gets a free one beside its HTTP port.
	ports: native: #Port | *defaultTcpPort
	// Written by enve on the service's ports (`config.xml` in its data dir); a project
	// that configures clickhouse itself supplies its own through `files:`.
	configFile: string | *"$DATA_DIR/config.xml"
	timeout:    #Duration | *defaultTimeout
	command:    string | *"clickhouse-server --config-file=\"\(configFile)\""
	environment: {
		CLICKHOUSE_DATA_DIR:  "$DATA_DIR"
		CLICKHOUSE_HTTP_PORT: "$PORT"
		CLICKHOUSE_TCP_PORT:  "$PORT_NATIVE"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		path:    string | *"/ping"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"curl -s -f \"http://127.0.0.1:$PORT/?query=SELECT+1\""
		timeout: #Duration | *defaultTimeout
	}
}

#TemporalService: #Service & {
	package: #PackageRef | *"temporal-cli"

	let defaultPort = 7233
	let defaultTimeout = "2500ms"

	port:       #Port | *defaultPort
	dbFilename: string | *"$DATA_DIR/temporal.db"
	timeout:    #Duration | *defaultTimeout
	command:    string | *"temporal server start-dev --port $PORT --headless --db-filename \"\(dbFilename)\""
	environment: {
		TEMPORAL_PORT: "$PORT"
		TEMPORAL_HOST: "127.0.0.1"
	}
	let servicePort = port

	// The frontend's gRPC health service, through the closure's own CLI.
	healthCheck: {
		port:    #Port | *servicePort
		command: string | *"temporal operator cluster health --address 127.0.0.1:$PORT"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"temporal operator cluster health --address 127.0.0.1:$PORT"
		timeout: #Duration | *defaultTimeout
	}
}

#SeaweedfsService: #Service & {
	package: #PackageRef | *"seaweedfs"

	let defaultPort = 19000

	// `weed server` is four servers and S3 is the last to listen: ~3.2s measured, so
	// the old 4s health budget lost the coin toss as soon as raft took a little longer.
	let defaultTimeout = "15000ms"

	port: #Port | *defaultPort
	// `weed server` listens seven times beyond S3 (master, volume, filer and their grpc
	// ports, the S3 grpc port), each a port slot so a named instance gets free ones.
	// The command naming them all is the conventions layer's, written from these slots
	// (`ports.filer`, `ports.master_grpc`, ... default from them).
	ports: {
		master: #Port | *19001
		volume: #Port | *19002
	}
	timeout: #Duration | *defaultTimeout
	environment: {
		S3_PORT:     "$PORT"
		S3_ENDPOINT: "http://127.0.0.1:$PORT"
	}
	let servicePort = port

	// The S3 gateway's health endpoint: `weed server` is one process, so one hung is all
	// four servers hung.
	healthCheck: {
		port:    #Port | *servicePort
		path:    string | *"/healthz"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"curl -s -f -o /dev/null http://127.0.0.1:$PORT/"
		timeout: #Duration | *"12000ms"
	}
}

#NginxService: #Service & {
	package: #PackageRef | *"nginx"

	let defaultPort = 8080
	let defaultTimeout = "2000ms"

	port: #Port | *defaultPort
	// The prefix nginx resolves its config, pid and temp paths against: the data dir,
	// where enve writes `nginx.conf` on the service's port.
	runDir: string | *"$DATA_DIR"
	// The config lives with the service, not at `/etc/nginx/nginx.conf`: the host's file
	// is absent on a clean machine and, where it exists, asks for port 80 and writes to
	// /var/log/nginx. Declaring `nginx` under `services:` has enve write one; a project
	// that configures nginx itself supplies its own through `files:`.
	configFile: string | *"\(runDir)/nginx.conf"
	timeout:    #Duration | *defaultTimeout
	// `-e stderr` because nginx opens its compiled-in `logs/error.log` before it reads a
	// line of the config, and that directory does not exist under a fresh prefix.
	command: string | *"nginx -p \"\(runDir)\" -c \"\(configFile)\" -e stderr -g \"daemon off;\""
	let servicePort = port

	// Any answer below 500 is a live server, as readiness takes it.
	healthCheck: {
		port:    #Port | *servicePort
		path:    string | *"/"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		path:    string | *"/"
		timeout: #Duration | *defaultTimeout
	}
}

#GarageService: #Service & {
	package: #PackageRef | *"garage"

	let defaultPort = 3900
	let defaultTimeout = "4000ms"

	// Garage listens three times: S3 for clients, RPC between nodes, and the admin API
	// readiness asks. Upstream puts the admin API on 3903; enve puts the two extra
	// listeners beside the S3 port, so one declared port moves all three and two
	// instances never collide. That arithmetic lives in the conventions layer, which is
	// what a `garage: {}` declaration goes through, and it is what writes the config
	// the server reads. These are its answers for the default port, spelled out
	// because a CUE default cannot compute one — so a preset that sets `port` should
	// set `ports.rpc` and `ports.admin` beside it rather than leave them at 3901/3902.
	// Each is a port slot (`$PORT_RPC`, `$PORT_ADMIN`): a named instance gets free ones.
	port: #Port | *defaultPort
	ports: {
		rpc:   #Port | *3901
		admin: #Port | *3902
	}
	// Written by enve when `garage` is declared under `services:`. A project that
	// configures garage itself supplies its own through `files:`.
	configFile: string | *"$DATA_DIR/garage.toml"
	timeout:    #Duration | *defaultTimeout
	command:    string | *"garage -c \"\(configFile)\" server"
	// The variables seaweedfs exports, so code that reads them works against either.
	environment: {
		AWS_ENDPOINT_URL:   "http://127.0.0.1:$PORT"
		S3_ENDPOINT:        "http://127.0.0.1:$PORT"
		AWS_DEFAULT_REGION: "garage"
	}
	let adminEndpoint = ports.admin
	healthCheck: {
		port:    #Port | *adminEndpoint
		path:    string | *"/health"
		timeout: #Duration | *"5s"
	}
	// `/health` answers as soon as the node is up and before a layout exists, which is what
	// makes it usable: the layout is applied by `postStart`, after readiness has passed.
	readinessProbe: {
		port:    #Port | *adminEndpoint
		path:    string | *"/health"
		timeout: #Duration | *defaultTimeout
	}
}

#NisshiService: #Service & {
	package: #PackageRef | *"nisshi"

	let defaultPort = 9092
	let defaultTimeout = "1500ms"

	port: #Port | *defaultPort
	// On disk rather than `memory://nisshi/`, which lost every topic on restart.
	// `$DATA_DIR` is absolute, so this is `sqlite:///<path>`: an empty host, which is
	// load-bearing, since `sqlite://<relative path>` reads the path as the URL's host.
	storageEngine: string | *"sqlite://$DATA_DIR/nisshi.db"
	timeout:       #Duration | *defaultTimeout
	command:       string | *"nisshi --listener-url tcp://127.0.0.1:$PORT --advertised-listener-url tcp://127.0.0.1:$PORT --storage-engine \(storageEngine)"
	environment: {
		KAFKA_PORT:    "$PORT"
		KAFKA_BROKERS: "127.0.0.1:$PORT"
	}
	let servicePort = port

	// A Kafka metadata request through the broker's own CLI.
	healthCheck: {
		port:    #Port | *servicePort
		command: string | *"nisshi topic list --broker tcp://127.0.0.1:$PORT"
		timeout: #Duration | *"5s"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		timeout: #Duration | *"1000ms"
	}
}

#KafkaService: #Service & {
	package: #PackageRef | *"apacheKafka"
	port:    #Port | *9092
	timeout: #Duration | *"30s"
	command: string | *"cd \"$DATA_DIR\" && exec kafka-server-start.sh server.properties"
	// Configuration, controllerPort, storage initialization and probes are injected
	// by the same conventions as `services: kafka: {}`.
}
#TansuService: #NisshiService

// `raw` as one POSIX shell word: single-quoted, each `'` closed, escaped and reopened.
_#ShellQuoted: {
	raw: string
	out: "'" + strings.Replace(raw, "'", "'\\''", -1) + "'"
}

// `raw` as one URL userinfo or path segment: every printable ASCII character outside
// RFC 3986's unreserved set percent-encoded, `%` first; non-ASCII stays as it is. (A
// comprehension over the characters would be shorter; cue-rs does not evaluate one
// whose result another field references.)
_#URLComponent: {
	raw: string
	let s0 = strings.Replace(raw, "%", "%25", -1)
	let s1 = strings.Replace(s0, " ", "%20", -1)
	let s2 = strings.Replace(s1, "!", "%21", -1)
	let s3 = strings.Replace(s2, "\"", "%22", -1)
	let s4 = strings.Replace(s3, "#", "%23", -1)
	let s5 = strings.Replace(s4, "$", "%24", -1)
	let s6 = strings.Replace(s5, "&", "%26", -1)
	let s7 = strings.Replace(s6, "'", "%27", -1)
	let s8 = strings.Replace(s7, "(", "%28", -1)
	let s9 = strings.Replace(s8, ")", "%29", -1)
	let s10 = strings.Replace(s9, "*", "%2A", -1)
	let s11 = strings.Replace(s10, "+", "%2B", -1)
	let s12 = strings.Replace(s11, ",", "%2C", -1)
	let s13 = strings.Replace(s12, "/", "%2F", -1)
	let s14 = strings.Replace(s13, ":", "%3A", -1)
	let s15 = strings.Replace(s14, ";", "%3B", -1)
	let s16 = strings.Replace(s15, "<", "%3C", -1)
	let s17 = strings.Replace(s16, "=", "%3D", -1)
	let s18 = strings.Replace(s17, ">", "%3E", -1)
	let s19 = strings.Replace(s18, "?", "%3F", -1)
	let s20 = strings.Replace(s19, "@", "%40", -1)
	let s21 = strings.Replace(s20, "[", "%5B", -1)
	let s22 = strings.Replace(s21, "\\", "%5C", -1)
	let s23 = strings.Replace(s22, "]", "%5D", -1)
	let s24 = strings.Replace(s23, "^", "%5E", -1)
	let s25 = strings.Replace(s24, "`", "%60", -1)
	let s26 = strings.Replace(s25, "{", "%7B", -1)
	let s27 = strings.Replace(s26, "|", "%7C", -1)
	let s28 = strings.Replace(s27, "}", "%7D", -1)
	out: s28
}

// A selectable configuration: the tools, services and environment variables
// that `enve` applies. Selected with `-p/--profile`; see `profiles` in the enve file.
#Profile: {
	name?:     string | *""
	pathMode?: #PathModeType
	build?:    #BuildSpec
	tools?: [...#PackageRef] | *[]
	services?: [string]: #Service
	disabledServices?: [...#Service]
	hosts?: [string]: string
	ports?: [...#Port]
	gitHooks?: #GitHooks
	environment?: [string]: _
	shellHook?: string
	resources?: _
	telemetry?: _
	[string]:   _
}

#CueOnlyDevEnvironment: {
	name?:     string | *""
	pathMode?: #PathModeType
	build?:    #BuildSpec
	tools?: [...#PackageRef] | *[]
	services?: [string]: #Service
	disabledServices?: [...#Service]
	hosts?: [string]: string
	ports?: [...#Port]
	gitHooks?: #GitHooks
	environment?: [string]: _
	shellHook?: string
	resources?: _
	telemetry?: _
	[string]:   _
}

// The profiles an enve file declares: `profiles: schema.#Profiles & {dev: …, ci: …}`.
// `-p/--profile` selects one by key, and `dev` is selected when the flag is absent.
#Profiles: [string]: #Profile
