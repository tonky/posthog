package schema

import (
	"time"
	"net"
)

#Duration: time.Duration | (int & > 0)
#Host:     net.IP | string

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

#ServiceHealthCheck: {
	port?:       #Port
	path?:       string
	command?:    string
	interval?:   #Duration
	intervalMs?: int & > 0 | *10000
	timeout?:    #Duration
	timeoutMs?:  int & > 0
	retries?:    int & > 0 | *3
}

#ServiceReadinessProbe: {
	port?:           #Port
	path?:           string
	command?:        string
	initialDelay?:   #Duration
	initialDelayMs?: int & >= 0 | *0
	timeout?:        #Duration
	timeoutMs?:      int & > 0
}

#ServiceFile: {
	target?:  string
	content?: string
	source?:  string
	mode?:    string | *"0644"
}

#LifecycleHook: string | [...string]

#ServiceLifecycle: {
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

#ServiceResources: {
	cpu?:         string | float | int
	ram?:         string | float | int
	cpuPercent?:  float | int
	ramMb?:       float | int
	startup?:     #Duration
	startupMs?:   int & >= 0
	health?:      #Duration
	healthMs?:    int & >= 0
	readiness?:   #Duration
	readinessMs?: int & >= 0
	[string]:     _
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
#PythonPackageFormatMode: #PythonPackageFormat.Pyproject | #PythonPackageFormat.Wheel | #PythonPackageFormat.Setuptools | string | *#PythonPackageFormat.Pyproject

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
#LogLevelMode: #LogLevel.Error | #LogLevel.Warn | #LogLevel.Info | #LogLevel.Debug | #LogLevel.Trace | string | *#LogLevel.Info

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
#GoToolchainMode: #GoToolchain.Auto | #GoToolchain.Local | #GoToolchain.Path | string | *#GoToolchain.Auto

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
	service:    _
	condition:  #DependencyConditionMode
	timeout?:   #Duration
	timeoutMs?: int & > 0
}

#DependencyRef: string | #ServiceDependency

#ServiceDependencyMap: [string]: {
	condition?: #DependencyConditionMode
	timeout?:   #Duration
	timeoutMs?: int & > 0
}

#Service: {
	name?:           string
	external?:       bool | *false
	host?:           #Host | *"127.0.0.1"
	url?:            string
	package?:        #PackageRef
	packages?:       [...#PackageRef]
	image?:          string
	command?:        string
	build?:          #BuildSpec
	directory?:      string | *"."
	watch?:          [...string]
	dataDir?:        string
	files?:          [string]: #ServiceFile | string
	lifecycle?:      #ServiceLifecycle
	port?:           #Port
	timeout?:        #Duration
	timeoutMs?:      int & > 0
	environment?:    [string]: _
	dependsOn?:      [...#DependencyRef] | #ServiceDependencyMap
	volumes?:        [...string]
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
	custom?:        [string]: string
}

#RuntimeMap: {
	go?:     _
	rust?:   _
	node?:   _
	python?: _
	ruby?:   _
	gleam?:  _
	erlang?: _
	zig?:    _
	roc?:    _
	elixir?: _
	[string]: _
}

#PostgresService: #Service & {
	package: #PackageRef | *"postgresql"

	let defaultPort = 5432
	let defaultDataDir = ".enve/data/postgres"
	let defaultDb = "postgres"
	let defaultUser = "postgres"
	let defaultSocketDir = "/tmp"
	let defaultTimeout = "2500ms"

	port:        #Port | *defaultPort
	dataDir:     string | *defaultDataDir
	socketDir:   string | *defaultSocketDir
	database:    string | *defaultDb
	user:        string | *defaultUser
	timeout:     #Duration | *defaultTimeout
	timeoutMs:   int | *2500
	command:     string | *"postgres -D \(dataDir) -k \(socketDir) -p \(port)"
	lifecycle: {
		init: [
			*"initdb -D $DATA_DIR -U postgres --auth-local=trust --auth-host=trust" | string,
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
		port:      #Port | *servicePort
		command:   string | *"pg_isready -h 127.0.0.1 -p \(servicePort) -U \(user)"
		timeout:   #Duration | *"1000ms"
		timeoutMs: int | *1000
	}
	readinessProbe: {
		port:      #Port | *servicePort
		command:   string | *"psql -h 127.0.0.1 -p \(servicePort) -U \(user) -d \(database) -c 'SELECT 1;'"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *2500
	}
}

#RedisService: #Service & {
	package: #PackageRef | *"redis"

	let defaultPort = 6379
	let defaultDataDir = ".enve/data/redis"
	let defaultTimeout = "1500ms"

	port:        #Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     #Duration | *defaultTimeout
	timeoutMs:   int | *1500
	command:     string | *"redis-server --port \(port) --dir \(dataDir) --daemonize no"
	environment: {
		REDIS_PORT: "\(port)"
		REDIS_URL:  "redis://localhost:\(port)/0"
	}
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		timeout:   #Duration | *"800ms"
		timeoutMs: int | *800
	}
	readinessProbe: {
		port:      #Port | *servicePort
		command:   string | *"redis-cli -p \(servicePort) ping"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *1500
	}
}

#MySQLService: #Service & {
	package: #PackageRef | *"mariadb"

	let defaultPort = 3306
	let defaultDataDir = ".enve/data/mysql"
	let defaultTimeout = "3500ms"

	port:        #Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     #Duration | *defaultTimeout
	timeoutMs:   int | *3500
	lifecycle: {
		init: [
			*"mysqld --initialize-insecure --datadir=\"$DATA_DIR\"" | string,
		]
	}
	command:     string | *"mysqld --datadir=\(dataDir) --port=\(port)"
	environment: {
		MYSQL_TCP_PORT: "\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		timeout:   #Duration | *"1500ms"
		timeoutMs: int | *1500
	}
	readinessProbe: {
		port:      #Port | *servicePort
		command:   string | *"mysqladmin ping -h 127.0.0.1 -P \(servicePort)"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *3500
	}
}

#ClickHouseService: #Service & {
	package: #PackageRef | *"clickhouse"

	let defaultHttpPort = 8123
	let defaultTcpPort = 9000
	let defaultDataDir = ".enve/data/clickhouse"
	let defaultConfigFile = ".enve/config/clickhouse/config.xml"
	let defaultTimeout = "3500ms"

	port:        #Port | *defaultHttpPort
	tcpPort:     #Port | *defaultTcpPort
	dataDir:     string | *defaultDataDir
	configFile:  string | *defaultConfigFile
	timeout:     #Duration | *defaultTimeout
	timeoutMs:   int | *3500
	command:     string | *"clickhouse-server --config-file=\(defaultConfigFile)"
	environment: {
		CLICKHOUSE_DATA_DIR:  defaultDataDir
		CLICKHOUSE_HTTP_PORT: "\(defaultHttpPort)"
		CLICKHOUSE_TCP_PORT:  "\(defaultTcpPort)"
	}
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/ping"
		timeout:   #Duration | *"1000ms"
		timeoutMs: int | *1000
	}
	readinessProbe: {
		port:      #Port | *servicePort
		command:   string | *"curl -s -f 'http://127.0.0.1:\(servicePort)/?query=SELECT+1'"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *3500
	}
}

#TemporalService: #Service & {
	package: #PackageRef | *"temporal-cli"

	let defaultPort = 7233
	let defaultDataDir = ".enve/data/temporal"
	let defaultDbFilename = ".enve/data/temporal/temporal.db"
	let defaultTimeout = "2500ms"

	port:        #Port | *defaultPort
	dataDir:     string | *defaultDataDir
	dbFilename:  string | *defaultDbFilename
	timeout:     #Duration | *defaultTimeout
	timeoutMs:   int | *2500
	command:     string | *"temporal server start-dev --port \(port) --headless --db-filename \(dbFilename)"
	environment: {
		TEMPORAL_PORT: "\(port)"
		TEMPORAL_HOST: "127.0.0.1"
	}
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		timeout:   #Duration | *"1000ms"
		timeoutMs: int | *1000
	}
	readinessProbe: {
		port:      #Port | *servicePort
		command:   string | *"temporal operator cluster health --address 127.0.0.1:\(servicePort)"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *2500
	}
}

#SeaweedfsService: #Service & {
	package: #PackageRef | *"seaweedfs"

	let defaultPort = 19000
	let defaultDataDir = ".enve/data/seaweedfs"
	let defaultTimeout = "6000ms"

	port:        #Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     #Duration | *defaultTimeout
	timeoutMs:   int | *6000
	command:     string | *"weed server -s3 -s3.port=\(port) -dir=\(dataDir)"
	environment: {
		S3_PORT:     "\(port)"
		S3_ENDPOINT: "http://127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		timeout:   #Duration | *"4000ms"
		timeoutMs: int | *4000
	}
	readinessProbe: {
		port:      #Port | *servicePort
		command:   string | *"curl -s -f -o /dev/null http://127.0.0.1:\(servicePort)/"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *6000
	}
}

#NginxService: #Service & {
	package: #PackageRef | *"nginx"

	let defaultPort = 8080
	let defaultConfigFile = "/etc/nginx/nginx.conf"
	let defaultRunDir = ".enve/data/nginx"
	let defaultTimeout = "2000ms"

	port:          #Port | *defaultPort
	configFile:    string | *defaultConfigFile
	runDir:        string | *defaultRunDir
	timeout:       #Duration | *defaultTimeout
	timeoutMs:     int | *2000
	command:       string | *"nginx -p \(runDir) -c \(configFile) -g 'daemon off;'"
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		timeout:   #Duration | *"1000ms"
		timeoutMs: int | *1000
	}
	readinessProbe: {
		port:      #Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *2000
	}
}

#MinioService: #Service & {
	package: #PackageRef | *"minio"

	let defaultPort = 9000
	let defaultConsolePort = 9001
	let defaultDataDir = ".enve/data/minio"
	let defaultTimeout = "3000ms"

	port:               #Port | *defaultPort
	consolePort:        #Port | *defaultConsolePort
	dataDir:            string | *defaultDataDir
	timeout:            #Duration | *defaultTimeout
	timeoutMs:          int | *3000
	command:            string | *"minio server \(dataDir) --address :\(port) --console-address :\(consolePort)"
	environment: {
		MINIO_PORT:          "\(port)"
		MINIO_CONSOLE_PORT:  "\(consolePort)"
		MINIO_ROOT_USER:     "minioadmin"
		MINIO_ROOT_PASSWORD: "minioadmin"
		S3_ENDPOINT:         "http://localhost:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/minio/health/live"
		timeout:   #Duration | *"1500ms"
		timeoutMs: int | *1500
	}
	readinessProbe: {
		port:      #Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/minio/health/ready"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *3000
	}
}

#RedpandaService: #Service & {
	package: #PackageRef | *"redpanda"

	let defaultKafkaPort = 9092
	let defaultAdminPort = 9644
	let defaultDataDir = ".enve/data/redpanda"
	let defaultTimeout = "4000ms"

	port:        #Port | *defaultKafkaPort
	adminPort:   #Port | *defaultAdminPort
	dataDir:     string | *defaultDataDir
	timeout:     #Duration | *defaultTimeout
	timeoutMs:   int | *4000
	command:     string | *"redpanda start --mode dev-container --kafka-addr 127.0.0.1:\(port) --admin-addr 127.0.0.1:\(adminPort) --dir \(dataDir) --smp 1 --memory 512M --reserve-memory 0M --check=false"
	environment: {
		KAFKA_PORT:     "\(port)"
		KAFKA_BROKERS:  "127.0.0.1:\(port)"
		REDPANDA_ADMIN: "127.0.0.1:\(adminPort)"
	}
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		timeout:   #Duration | *"1500ms"
		timeoutMs: int | *1500
	}
	readinessProbe: {
		port:      #Port | *adminPort
		path:      string | *"http://127.0.0.1:\(adminPort)/v1/cluster/ready"
		timeout:   #Duration | *defaultTimeout
		timeoutMs: int | *4000
	}
}

#TansuService: #Service & {
	package: #PackageRef | *"tansu"

	let defaultPort = 9092
	let defaultEngine = "memory://tansu/"
	let defaultTimeout = "1500ms"

	port:          #Port | *defaultPort
	storageEngine: string | *defaultEngine
	timeout:       #Duration | *defaultTimeout
	timeoutMs:     int | *1500
	command:       string | *"tansu --listener-url tcp://127.0.0.1:\(port) --advertised-listener-url tcp://127.0.0.1:\(port) --storage-engine \(storageEngine)"
	environment: {
		KAFKA_PORT:    "\(port)"
		KAFKA_BROKERS: "127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      #Port | *servicePort
		timeout:   #Duration | *"800ms"
		timeoutMs: int | *800
	}
	readinessProbe: {
		port:      #Port | *servicePort
		timeout:   #Duration | *"1000ms"
		timeoutMs: int | *1000
	}
}

#KafkaService: #TansuService

#DevEnvironment: {
	name?:        string | *""
	build?:       #BuildSpec
	tools?:       [..._] | *[]
	runtimes?:    #RuntimeMap
	services?:    [string]: #Service
	hosts?:       [string]: string
	ports?:       [...#Port]
	gitHooks?:    #GitHooks
	environment?: [string]: _
	shellHook?:   string
	resources?:   _
	telemetry?:   _
	[string]:     _
}

#CueOnlyDevEnvironment: {
	name?:        string | *""
	build?:       #BuildSpec
	tools?:       [..._] | *[]
	runtimes?:    #RuntimeMap
	services?:    [string]: #Service
	hosts?:       [string]: string
	ports?:       [...#Port]
	gitHooks?:    #GitHooks
	environment?: [string]: _
	shellHook?:   string
	resources?:   _
	telemetry?:   _
	[string]:     _
}

#GoBuildSpec:     #BuildSpec
#NodeBuildSpec:   #BuildSpec
#PythonBuildSpec: #BuildSpec & {
	format?: #PythonPackageFormatMode
}
#RustBuildSpec:   #BuildSpec
#GleamBuildSpec: #BuildSpec
#ErlangBuildSpec: #BuildSpec

// Canonical aliases
#Environment: #DevEnvironment
#Enve:        #DevEnvironment

