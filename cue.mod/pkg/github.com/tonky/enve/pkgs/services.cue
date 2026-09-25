package pkgs

import "github.com/tonky/enve/schema/v1:schema"

// -------------------------------------------------------------
// Local Developer Services, Databases & Container Tools
// -------------------------------------------------------------

postgres: {pname: "postgresql"}
postgresql: {pname: "postgresql"}
postgresql_18: {pname: "postgresql", version: "18"}
postgresql_17: {pname: "postgresql", version: "17"}
postgresql_16: {pname: "postgresql", version: "16"}
postgresql_15: {pname: "postgresql", version: "15"}
postgresql_14: {pname: "postgresql", version: "14"}

redis: {pname: "redis"}
valkey: {pname: "valkey"}
docker_compose: {pname: "docker-compose"}
mysql: {pname: "mysql"}
mariadb: {pname: "mariadb"}
garage: {pname: "garage"}
mailpit: {pname: "mailpit"}
clickhouse: {pname: "clickhouse"}
temporal: {pname: "temporal-cli"}
seaweedfs: {pname: "seaweedfs"}
tansu: {pname: "tansu"}
kafka: {pname: "tansu"}

// -------------------------------------------------------------
// High-Level Microservice & Daemon Presets (#Service presets)
// -------------------------------------------------------------

#PostgresService: schema.#Service & {
	package: schema.#PackageRef | *"postgresql"

	let defaultPort = 5432
	let defaultDataDir = ".enve/data/postgres"
	let defaultDb = "postgres"
	let defaultUser = "postgres"
	let defaultTimeout = "2500ms"

	port:    schema.#Port | *defaultPort
	dataDir: string | *defaultDataDir
	// With the data, not in `/tmp`: a socket left behind by a crashed postmaster
	// otherwise blocks the next start of an unrelated project on the same port, which
	// is what the supervisor's stale-socket sweep exists to paper over.
	socketDir: string | *dataDir
	database:  string | *defaultDb
	user:      string | *defaultUser
	timeout:   schema.#Duration | *defaultTimeout
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
		port:    schema.#Port | *servicePort
		command: string | *"pg_isready -h 127.0.0.1 -p \(servicePort) -U \(user)"
		timeout: schema.#Duration | *"1000ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		command: string | *"psql -h 127.0.0.1 -p \(servicePort) -U \(user) -d \(database) -c 'SELECT 1;'"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#RedisService: schema.#Service & {
	package: schema.#PackageRef | *"redis"

	let defaultPort = 6379
	let defaultDataDir = ".enve/data/redis"
	let defaultTimeout = "1500ms"

	port:    schema.#Port | *defaultPort
	dataDir: string | *defaultDataDir
	timeout: schema.#Duration | *defaultTimeout
	command: string | *"redis-server --port \(port) --dir \(dataDir) --daemonize no"
	environment: {
		REDIS_PORT: "\(port)"
		REDIS_URL:  "redis://localhost:\(port)/0"
	}
	let servicePort = port
	healthCheck: {
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"800ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		command: string | *"redis-cli -p \(servicePort) ping"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#ValkeyService: schema.#Service & {
	package: schema.#PackageRef | *"valkey"

	let defaultPort = 6379
	let defaultDataDir = ".enve/data/valkey"
	let defaultTimeout = "1500ms"

	port:    schema.#Port | *defaultPort
	dataDir: string | *defaultDataDir
	timeout: schema.#Duration | *defaultTimeout
	command: string | *"valkey-server --port \(port) --dir \(dataDir) --daemonize no"
	// Valkey answers the Redis protocol, so its clients read the Redis variables.
	environment: {
		REDIS_PORT: "\(port)"
		REDIS_URL:  "redis://localhost:\(port)/0"
	}
	let servicePort = port
	healthCheck: {
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"800ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		command: string | *"valkey-cli -p \(servicePort) ping"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#GarageService: schema.#Service & {
	package: schema.#PackageRef | *"garage"

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
	port: schema.#Port | *defaultPort
	let defaultRpcPort = 3901
	let defaultAdminPort = 3902
	rpcPort:   schema.#Port | *defaultRpcPort
	adminPort: schema.#Port | *defaultAdminPort
	dataDir:   string | *defaultDataDir
	// Written by enve when `garage` is declared under `services:`. A project that
	// configures garage itself supplies its own through `files:`.
	configFile: string | *"\(dataDir)/garage.toml"
	timeout:    schema.#Duration | *defaultTimeout
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
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"1500ms"
	}
	// `/health` answers as soon as the node is up and before a layout exists, which is what
	// makes it usable: the layout is applied by `postStart`, after readiness has passed.
	readinessProbe: {
		port:    schema.#Port | *adminEndpoint
		path:    string | *"http://127.0.0.1:\(adminEndpoint)/health"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#NginxService: schema.#Service & {
	package: schema.#PackageRef | *"nginx"

	let defaultPort = 8080
	let defaultDataDir = ".enve/data/nginx"
	let defaultRunDir = defaultDataDir
	let defaultTimeout = "2000ms"

	port:   schema.#Port | *defaultPort
	runDir: string | *defaultRunDir
	// The config lives with the service, not at `/etc/nginx/nginx.conf`: the host's file
	// is absent on a clean machine and, where it exists, asks for port 80 and writes to
	// /var/log/nginx. Declaring `nginx` under `services:` has enve write one; a project
	// that configures nginx itself supplies its own through `files:`.
	configFile: string | *"\(runDir)/nginx.conf"
	timeout:    schema.#Duration | *defaultTimeout
	// `-e stderr` because nginx opens its compiled-in `logs/error.log` before it reads a
	// line of the config, and that directory does not exist under a fresh prefix.
	command: string | *"nginx -p \"\(runDir)\" -c \"\(configFile)\" -e stderr -g \"daemon off;\""
	let servicePort = port
	healthCheck: {
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"1000ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		path:    string | *"http://127.0.0.1:\(servicePort)/"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#MySQLService: schema.#Service & {
	package: schema.#PackageRef | *"mysql"

	let defaultPort = 3306
	let defaultDataDir = ".enve/data/mysql"
	let defaultTimeout = "3500ms"

	port:    schema.#Port | *defaultPort
	dataDir: string | *defaultDataDir
	timeout: schema.#Duration | *defaultTimeout
	lifecycle: {
		init: [
			*"mysqld --no-defaults --initialize-insecure --datadir=\"$DATA_DIR\"" | string,
		]
	}
	// Every path under the data directory: the socket and the pid file both default
	// into a shared location (`/tmp/mysql.sock`), which a second instance would take
	// from the first. `--mysqlx=OFF` closes the X protocol listener, whose own
	// default port (33060) is not the one this service was given.
	command: string | *"mysqld --no-defaults --datadir=\"\(dataDir)\" --port=\(port) --socket=\"\(dataDir)/mysql.sock\" --pid-file=\"\(dataDir)/mysqld.pid\" --mysqlx=OFF --bind-address=127.0.0.1"
	environment: {
		MYSQL_TCP_PORT: "\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"1500ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		command: string | *"mysqladmin ping -h 127.0.0.1 -P \(servicePort) -u root"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#MariaDBService: schema.#Service & {
	package: schema.#PackageRef | *"mariadb"

	let defaultPort = 3306
	let defaultDataDir = ".enve/data/mariadb"
	let defaultTimeout = "3500ms"

	port:    schema.#Port | *defaultPort
	dataDir: string | *defaultDataDir
	timeout: schema.#Duration | *defaultTimeout
	lifecycle: {
		init: [
			*"mariadb-install-db --no-defaults --datadir=\"$DATA_DIR\" --auth-root-authentication-method=normal" | string,
		]
	}
	command: string | *"mariadbd --no-defaults --datadir=\"\(dataDir)\" --port=\(port) --socket=\"\(dataDir)/mysql.sock\" --pid-file=\"\(dataDir)/mariadbd.pid\" --bind-address=127.0.0.1"
	environment: {
		MYSQL_TCP_PORT: "\(port)"
		MARIADB_PORT:   "\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"1500ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		command: string | *"mariadb-admin ping -h 127.0.0.1 -P \(servicePort) -u root"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#ClickHouseService: schema.#Service & {
	package: schema.#PackageRef | *"clickhouse"

	let defaultPort = 8123
	let defaultHttpPort = defaultPort
	let defaultTcpPort = 9000
	let defaultDataDir = ".enve/data/clickhouse"
	let defaultConfigFile = ".enve/config/clickhouse/config.xml"
	let defaultTimeout = "3500ms"

	port:       schema.#Port | *defaultHttpPort
	tcpPort:    schema.#Port | *defaultTcpPort
	dataDir:    string | *defaultDataDir
	configFile: string | *defaultConfigFile
	timeout:    schema.#Duration | *defaultTimeout
	command:    string | *"clickhouse-server --config-file=\(defaultConfigFile)"
	environment: {
		CLICKHOUSE_DATA_DIR:  defaultDataDir
		CLICKHOUSE_HTTP_PORT: "\(defaultHttpPort)"
		CLICKHOUSE_TCP_PORT:  "\(defaultTcpPort)"
	}
	let servicePort = port
	healthCheck: {
		port:    schema.#Port | *servicePort
		path:    string | *"http://127.0.0.1:\(servicePort)/ping"
		timeout: schema.#Duration | *"1000ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		command: string | *"curl -s -f 'http://127.0.0.1:\(servicePort)/?query=SELECT+1'"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#TemporalService: schema.#Service & {
	package: schema.#PackageRef | *"temporal-cli"

	let defaultPort = 7233
	let defaultDataDir = ".enve/data/temporal"
	let defaultDbFilename = ".enve/data/temporal/temporal.db"
	let defaultTimeout = "2500ms"

	port:       schema.#Port | *defaultPort
	dataDir:    string | *defaultDataDir
	dbFilename: string | *defaultDbFilename
	timeout:    schema.#Duration | *defaultTimeout
	command:    string | *"temporal server start-dev --port \(port) --headless --db-filename \(dbFilename)"
	environment: {
		TEMPORAL_PORT: "\(port)"
		TEMPORAL_HOST: "127.0.0.1"
	}
	let servicePort = port
	healthCheck: {
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"1000ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		command: string | *"temporal operator cluster health --address 127.0.0.1:\(servicePort)"
		timeout: schema.#Duration | *defaultTimeout
	}
}

#SeaweedfsService: schema.#Service & {
	package: schema.#PackageRef | *"seaweedfs"

	let defaultPort = 19000
	let defaultMasterPort = 19001
	let defaultVolumePort = 19002
	let defaultDataDir = ".enve/data/seaweedfs"

	// `weed server` is four servers and S3 is the last to listen: ~3.2s measured, so
	// the old 4s health budget lost the coin toss as soon as raft took a little longer.
	let defaultTimeout = "15000ms"

	port:       schema.#Port | *defaultPort
	masterPort: schema.#Port | *defaultMasterPort
	volumePort: schema.#Port | *defaultVolumePort
	dataDir:    string | *defaultDataDir
	timeout:    schema.#Duration | *defaultTimeout
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
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"12000ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		command: string | *"curl -s -f -o /dev/null http://127.0.0.1:\(servicePort)/"
		timeout: schema.#Duration | *"12000ms"
	}
}

#TansuService: schema.#Service & {
	package: schema.#PackageRef | *"tansu"

	let defaultPort = 9092
	let defaultDataDir = ".enve/data/tansu"
	let defaultTimeout = "1500ms"

	port:    schema.#Port | *defaultPort
	dataDir: string | *defaultDataDir
	// On disk rather than `memory://tansu/`, which lost every topic on restart. Tansu
	// resolves the URL's path against its working directory, so the path stays relative
	// and the `///` is load-bearing: `sqlite://<path>` reads `<path>` as the URL's host.
	storageEngine: string | *"sqlite:///\(dataDir)/tansu.db"
	timeout:       schema.#Duration | *defaultTimeout
	command:       string | *"tansu --listener-url tcp://127.0.0.1:\(port) --advertised-listener-url tcp://127.0.0.1:\(port) --storage-engine \(storageEngine)"
	environment: {
		KAFKA_PORT:    "\(port)"
		KAFKA_BROKERS: "127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"800ms"
	}
	readinessProbe: {
		port:    schema.#Port | *servicePort
		timeout: schema.#Duration | *"1000ms"
	}
}

#KafkaService: #TansuService
