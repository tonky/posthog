package schema

import (
	"time"
	"net"
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

// A nixpkgs commit. Every package in every profile is fetched from this one revision, so
// one closure holds one stdenv and one glibc. Declared once, beside `profiles`.
#NixpkgsRev: string & =~"^[0-9a-f]{40}$"

#Nixpkgs: {
	url?: string | *"github:NixOS/nixpkgs"
	rev:  #NixpkgsRev
}

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
#BuildSpec: {
	sandbox?:       #BuildSandbox
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

// A package in `tools`. `version` is honoured against the project's nixpkgs revision;
// `rev` overrides that revision for this package alone, for a version it cannot satisfy.
#PackageRef: string | {
	pname:     string
	version?:  #SemVer
	rev?:      #NixpkgsRev
	features?: _
	[string]:  _
}

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

#DependencyRef: #ServiceDependency | #Service

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
	name?:     string
	enabled?:  bool | *true
	external?: bool | *false
	host?:     #Host | *"127.0.0.1"
	url?:      string
	package?:  #PackageRef
	packages?: [...#PackageRef]
	image?:     string
	command?:   string
	build?:     #BuildSpec
	directory?: string | *"."
	originDir?: string
	watch?: [...string]
	dataDir?: string
	files?: [string]: #ServiceFile | string
	lifecycle?:         #ServiceLifecycle
	port?:              #Port
	timeout?:           #Duration
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
	isolation?:      #ServiceIsolationMode
	resources?:      #ServiceResources
	[string]:        _
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

#PostgresService: #Service & {
	package: #PackageRef | *"postgresql"

	let defaultPort = 5432
	let defaultDataDir = ".enve/data/postgres"
	let defaultDb = "postgres"
	let defaultUser = "postgres"
	let defaultTimeout = "2500ms"

	port:    #Port | *defaultPort
	dataDir: string | *defaultDataDir
	// With the data, not in `/tmp`: a socket left behind by a crashed postmaster
	// otherwise blocks the next start of an unrelated project on the same port, which
	// is what the supervisor's stale-socket sweep exists to paper over.
	socketDir: string | *dataDir
	database:  string | *defaultDb
	user:      string | *defaultUser
	timeout:   #Duration | *defaultTimeout
	command:   string | *"postgres -D \(dataDir) -k \(socketDir) -p \(port)"
	lifecycle: {
		init: [
			*"initdb -D \"$DATA_DIR\" -U postgres --auth-local=trust --auth-host=trust" | string,
		]
		// Postgres runs its checkpointer and walwriter as child processes, so the group
		// SIGTERM that stops every other service reaches them directly and the postmaster
		// reads that as a crash rather than a shutdown. Without this it never checkpoints,
		// and every later boot pays for an automatic recovery.
		preStop: [
			*"pg_ctl stop -D \"$DATA_DIR\" -m fast" | string,
		]
	}
	environment: {
		PGDATA:       dataDir
		PGPORT:       "\(port)"
		PGHOST:       socketDir
		PGUSER:       user
		DATABASE_URL: "postgresql://\(user)@localhost:\(port)/\(database)"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		command: string | *"pg_isready -h 127.0.0.1 -p \(servicePort) -U \(user)"
		timeout: #Duration | *"1000ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"psql -h 127.0.0.1 -p \(servicePort) -U \(user) -d \(database) -c 'SELECT 1;'"
		timeout: #Duration | *defaultTimeout
	}
}

#RedisService: #Service & {
	package: #PackageRef | *"redis"

	let defaultPort = 6379
	let defaultDataDir = ".enve/data/redis"
	let defaultTimeout = "1500ms"

	port:    #Port | *defaultPort
	dataDir: string | *defaultDataDir
	timeout: #Duration | *defaultTimeout
	command: string | *"redis-server --port \(port) --dir \(dataDir) --daemonize no"
	environment: {
		REDIS_PORT: "\(port)"
		REDIS_URL:  "redis://localhost:\(port)/0"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		timeout: #Duration | *"800ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"redis-cli -p \(servicePort) ping"
		timeout: #Duration | *defaultTimeout
	}
}

#ValkeyService: #Service & {
	package: #PackageRef | *"valkey"

	let defaultPort = 6379
	let defaultDataDir = ".enve/data/valkey"
	let defaultTimeout = "1500ms"

	port:    #Port | *defaultPort
	dataDir: string | *defaultDataDir
	timeout: #Duration | *defaultTimeout
	command: string | *"valkey-server --port \(port) --dir \(dataDir) --daemonize no"
	// Valkey answers the Redis protocol, so its clients read the Redis variables.
	environment: {
		REDIS_PORT: "\(port)"
		REDIS_URL:  "redis://localhost:\(port)/0"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		timeout: #Duration | *"800ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"valkey-cli -p \(servicePort) ping"
		timeout: #Duration | *defaultTimeout
	}
}

#MySQLService: #Service & {
	package: #PackageRef | *"mysql"

	let defaultPort = 3306
	let defaultDataDir = ".enve/data/mysql"
	let defaultTimeout = "3500ms"

	port:    #Port | *defaultPort
	dataDir: string | *defaultDataDir
	timeout: #Duration | *defaultTimeout
	lifecycle: {
		init: [
			*"mysqld --initialize-insecure --datadir=\"$DATA_DIR\"" | string,
		]
	}
	// Every path under the data directory: the socket and the pid file both default
	// into a shared location (`/tmp/mysql.sock`), which a second instance would take
	// from the first. `--mysqlx=OFF` closes the X protocol listener, whose own
	// default port (33060) is not the one this service was given.
	command: string | *"mysqld --datadir=\"\(dataDir)\" --port=\(port) --socket=\"\(dataDir)/mysql.sock\" --pid-file=\"\(dataDir)/mysqld.pid\" --mysqlx=OFF --bind-address=127.0.0.1"
	environment: {
		MYSQL_TCP_PORT: "\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		timeout: #Duration | *"1500ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"mysqladmin ping -h 127.0.0.1 -P \(servicePort) -u root"
		timeout: #Duration | *defaultTimeout
	}
}

#ClickHouseService: #Service & {
	package: #PackageRef | *"clickhouse"

	let defaultHttpPort = 8123
	let defaultTcpPort = 9000
	let defaultDataDir = ".enve/data/clickhouse"
	let defaultConfigFile = ".enve/config/clickhouse/config.xml"
	let defaultTimeout = "3500ms"

	port:       #Port | *defaultHttpPort
	tcpPort:    #Port | *defaultTcpPort
	dataDir:    string | *defaultDataDir
	configFile: string | *defaultConfigFile
	timeout:    #Duration | *defaultTimeout
	command:    string | *"clickhouse-server --config-file=\(defaultConfigFile)"
	environment: {
		CLICKHOUSE_DATA_DIR:  defaultDataDir
		CLICKHOUSE_HTTP_PORT: "\(defaultHttpPort)"
		CLICKHOUSE_TCP_PORT:  "\(defaultTcpPort)"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		path:    string | *"http://127.0.0.1:\(servicePort)/ping"
		timeout: #Duration | *"1000ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"curl -s -f 'http://127.0.0.1:\(servicePort)/?query=SELECT+1'"
		timeout: #Duration | *defaultTimeout
	}
}

#TemporalService: #Service & {
	package: #PackageRef | *"temporal-cli"

	let defaultPort = 7233
	let defaultDataDir = ".enve/data/temporal"
	let defaultDbFilename = ".enve/data/temporal/temporal.db"
	let defaultTimeout = "2500ms"

	port:       #Port | *defaultPort
	dataDir:    string | *defaultDataDir
	dbFilename: string | *defaultDbFilename
	timeout:    #Duration | *defaultTimeout
	command:    string | *"temporal server start-dev --port \(port) --headless --db-filename \(dbFilename)"
	environment: {
		TEMPORAL_PORT: "\(port)"
		TEMPORAL_HOST: "127.0.0.1"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		timeout: #Duration | *"1000ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"temporal operator cluster health --address 127.0.0.1:\(servicePort)"
		timeout: #Duration | *defaultTimeout
	}
}

#SeaweedfsService: #Service & {
	package: #PackageRef | *"seaweedfs"

	let defaultPort = 19000
	let defaultMasterPort = 19001
	let defaultVolumePort = 19002
	let defaultDataDir = ".enve/data/seaweedfs"

	// `weed server` is four servers and S3 is the last to listen: ~3.2s measured, so
	// the old 4s health budget lost the coin toss as soon as raft took a little longer.
	let defaultTimeout = "15000ms"

	port:       #Port | *defaultPort
	masterPort: #Port | *defaultMasterPort
	volumePort: #Port | *defaultVolumePort
	dataDir:    string | *defaultDataDir
	timeout:    #Duration | *defaultTimeout
	// -master.raftHashicorp: under the legacy raft a resumed single-node master answers
	// its own clients with `Not current leader` forever, so the second boot never serves.
	// -ip pins the advertised address: `weed` otherwise records whichever non-loopback
	// address it found into its raft state.
	command: string | *"weed server -ip=127.0.0.1 -master.raftHashicorp -s3 -s3.port=\(port) -master.port=\(masterPort) -volume.port=\(volumePort) -dir=\(dataDir)"
	environment: {
		S3_PORT:     "\(port)"
		S3_ENDPOINT: "http://127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		timeout: #Duration | *"12000ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		command: string | *"curl -s -f -o /dev/null http://127.0.0.1:\(servicePort)/"
		timeout: #Duration | *"12000ms"
	}
}

#NginxService: #Service & {
	package: #PackageRef | *"nginx"

	let defaultPort = 8080
	let defaultRunDir = ".enve/data/nginx"
	let defaultTimeout = "2000ms"

	port:   #Port | *defaultPort
	runDir: string | *defaultRunDir
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
	healthCheck: {
		port:    #Port | *servicePort
		timeout: #Duration | *"1000ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		path:    string | *"http://127.0.0.1:\(servicePort)/"
		timeout: #Duration | *defaultTimeout
	}
}

#GarageService: #Service & {
	package: #PackageRef | *"garage"

	let defaultPort = 3900
	let defaultDataDir = ".enve/data/garage"
	let defaultTimeout = "4000ms"

	// Garage listens three times: S3 for clients, RPC between nodes, and the admin API
	// readiness asks. Upstream puts the admin API on 3903; enve puts the two extra
	// listeners beside the S3 port, so one declared port moves all three and two
	// instances never collide. That arithmetic lives in the conventions layer, which is
	// what a `garage: {}` declaration goes through, and it is what writes the config
	// the server reads. These are its answers for the default port, spelled out
	// because a CUE default cannot compute one — so a preset that sets `port` should
	// set `rpcPort` and `adminPort` beside it rather than leave them at 3901/3902.
	port: #Port | *defaultPort
	let defaultRpcPort = 3901
	let defaultAdminPort = 3902
	rpcPort:   #Port | *defaultRpcPort
	adminPort: #Port | *defaultAdminPort
	dataDir:   string | *defaultDataDir
	// Written by enve when `garage` is declared under `services:`. A project that
	// configures garage itself supplies its own through `files:`.
	configFile: string | *"\(dataDir)/garage.toml"
	timeout:    #Duration | *defaultTimeout
	command:    string | *"garage -c \"\(configFile)\" server"
	// The variables seaweedfs exports, so code that reads them works against either.
	environment: {
		AWS_ENDPOINT_URL:   "http://127.0.0.1:\(port)"
		S3_ENDPOINT:        "http://127.0.0.1:\(port)"
		AWS_DEFAULT_REGION: "garage"
	}
	let servicePort = port
	let adminEndpoint = adminPort
	healthCheck: {
		port:    #Port | *servicePort
		timeout: #Duration | *"1500ms"
	}
	// `/health` answers as soon as the node is up and before a layout exists, which is what
	// makes it usable: the layout is applied by `postStart`, after readiness has passed.
	readinessProbe: {
		port:    #Port | *adminEndpoint
		path:    string | *"http://127.0.0.1:\(adminEndpoint)/health"
		timeout: #Duration | *defaultTimeout
	}
}

#TansuService: #Service & {
	package: #PackageRef | *"tansu"

	let defaultPort = 9092
	let defaultDataDir = ".enve/data/tansu"
	let defaultTimeout = "1500ms"

	port:    #Port | *defaultPort
	dataDir: string | *defaultDataDir
	// On disk rather than `memory://tansu/`, which lost every topic on restart. Tansu
	// resolves the URL's path against its working directory, so the path stays relative
	// and the `///` is load-bearing: `sqlite://<path>` reads `<path>` as the URL's host.
	storageEngine: string | *"sqlite:///\(dataDir)/tansu.db"
	timeout:       #Duration | *defaultTimeout
	command:       string | *"tansu --listener-url tcp://127.0.0.1:\(port) --advertised-listener-url tcp://127.0.0.1:\(port) --storage-engine \(storageEngine)"
	environment: {
		KAFKA_PORT:    "\(port)"
		KAFKA_BROKERS: "127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:    #Port | *servicePort
		timeout: #Duration | *"800ms"
	}
	readinessProbe: {
		port:    #Port | *servicePort
		timeout: #Duration | *"1000ms"
	}
}

#KafkaService: #TansuService

// A selectable configuration: the tools, services and environment variables
// that `enve` applies. Selected with `-p/--profile`; see `profiles` in the enve file.
#Profile: {
	name?:  string | *""
	build?: #BuildSpec
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
	name?:  string | *""
	build?: #BuildSpec
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

#GoBuildSpec:   #BuildSpec
#NodeBuildSpec: #BuildSpec
#PythonBuildSpec: #BuildSpec & {
	format?: #PythonPackageFormatMode
}
#RustBuildSpec:   #BuildSpec
#GleamBuildSpec:  #BuildSpec
#ErlangBuildSpec: #BuildSpec

// The profiles an enve file declares: `profiles: schema.#Profiles & {dev: …, ci: …}`.
// `-p/--profile` selects one by key, and `dev` is selected when the flag is absent.
#Profiles: [string]: #Profile
