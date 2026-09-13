package pkgs

import devshell "github.com/tonky/enve/schema/v1:schema"

// -------------------------------------------------------------
// Local Developer Services, Databases & Container Tools
// -------------------------------------------------------------

postgres: devshell.#RustBuildSpec & {
	pname:   "postgresql"
	version: "17.4"
	src:     "https://ftp.postgresql.org/pub/source/v17.4/postgresql-17.4.tar.gz"
}

postgresql: postgres
postgresql_17: postgres
postgresql_16: devshell.#RustBuildSpec & {
	pname:   "postgresql"
	version: "16.4"
	src:     "https://ftp.postgresql.org/pub/source/v16.4/postgresql-16.4.tar.gz"
}
postgresql_15: devshell.#RustBuildSpec & {
	pname:   "postgresql"
	version: "15.8"
	src:     "https://ftp.postgresql.org/pub/source/v15.8/postgresql-15.8.tar.gz"
}
postgresql_14: devshell.#RustBuildSpec & {
	pname:   "postgresql"
	version: "14.13"
	src:     "https://ftp.postgresql.org/pub/source/v14.13/postgresql-14.13.tar.gz"
}

redis: devshell.#RustBuildSpec & {
	pname:   "redis"
	version: "7.4.2"
	src:     "https://github.com/redis/redis/archive/refs/tags/7.4.2.tar.gz"
}

docker_compose: devshell.#GoBuildSpec & {
	pname:       "docker-compose"
	version:     "2.33.1"
	src:         "https://github.com/docker/compose/archive/refs/tags/v2.33.1.tar.gz"
	subPackages: "cmd"
}

mysql: devshell.#RustBuildSpec & {
	pname:   "mysql"
	version: "8.4.0"
	src:     "https://github.com/mysql/mysql-server/archive/refs/tags/mysql-8.4.0.tar.gz"
}

minio: devshell.#GoBuildSpec & {
	pname:       "minio"
	version:     "2025.2.7"
	src:         "https://github.com/minio/minio/archive/refs/tags/RELEASE.2025-02-07T23-21-09Z.tar.gz"
	subPackages: "."
}

mailpit: devshell.#GoBuildSpec & {
	pname:       "mailpit"
	version:     "1.21.8"
	src:         "https://github.com/axllent/mailpit/archive/refs/tags/v1.21.8.tar.gz"
	subPackages: "."
}

clickhouse: devshell.#RustBuildSpec & {
	pname:   "clickhouse"
	version: "26.1"
	src:     "https://github.com/ClickHouse/ClickHouse/archive/refs/tags/v26.1.1.1-stable.tar.gz"
}

temporal: devshell.#RustBuildSpec & {
	pname:   "temporal-cli"
	version: "1.2.0"
	src:     "https://github.com/temporalio/cli/archive/refs/tags/v1.2.0.tar.gz"
}

seaweedfs: devshell.#GoBuildSpec & {
	pname:       "seaweedfs"
	version:     "3.84"
	src:         "https://github.com/seaweedfs/seaweedfs/archive/refs/tags/3.84.tar.gz"
	subPackages: "."
}

redpanda: devshell.#GoBuildSpec & {
	pname:       "redpanda"
	version:     "24.3.4"
	src:         "https://github.com/redpanda-data/redpanda/archive/refs/tags/v24.3.4.tar.gz"
	subPackages: "src/go/rpk"
}

rpk: redpanda

tansu: devshell.#RustBuildSpec & {
	pname:   "tansu"
	version: "0.6.0-pre.9"
	src:     "https://github.com/nisshi-io/nisshi/archive/refs/tags/v0.6.0-pre.9.tar.gz"
}

kafka: tansu

// -------------------------------------------------------------
// High-Level Microservice & Daemon Presets (#Service presets)
// -------------------------------------------------------------

#PostgresService: devshell.#Service & {
	package: devshell.#PackageRef | *"postgresql"

	let defaultPort = 5432
	let defaultDataDir = ".enve/data/postgres"
	let defaultDb = "postgres"
	let defaultUser = "postgres"
	let defaultSocketDir = "/tmp"
	let defaultTimeout = "2500ms"

	port:        devshell.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	socketDir:   string | *defaultSocketDir
	database:    string | *defaultDb
	user:        string | *defaultUser
	timeout:     devshell.#Duration | *defaultTimeout
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
		port:      devshell.#Port | *servicePort
		command:   string | *"pg_isready -h 127.0.0.1 -p \(servicePort) -U \(user)"
		timeout:   devshell.#Duration | *"1000ms"
		timeoutMs: int | *1000
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		command:   string | *"psql -h 127.0.0.1 -p \(servicePort) -U \(user) -d \(database) -c 'SELECT 1;'"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *2500
	}
}

#RedisService: devshell.#Service & {
	package: devshell.#PackageRef | *"redis"

	let defaultPort = 6379
	let defaultDataDir = ".enve/data/redis"
	let defaultTimeout = "1500ms"

	port:        devshell.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     devshell.#Duration | *defaultTimeout
	timeoutMs:   int | *1500
	command:     string | *"redis-server --port \(port) --dir \(dataDir) --daemonize no"
	environment: {
		REDIS_PORT: "\(port)"
		REDIS_URL:  "redis://localhost:\(port)/0"
	}
	let servicePort = port
	healthCheck: {
		port:      devshell.#Port | *servicePort
		timeout:   devshell.#Duration | *"800ms"
		timeoutMs: int | *800
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		command:   string | *"redis-cli -p \(servicePort) ping"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *1500
	}
}

#MinioService: devshell.#Service & {
	package: devshell.#PackageRef | *"minio"

	let defaultPort = 9000
	let defaultConsolePort = 9001
	let defaultDataDir = ".enve/data/minio"
	let defaultTimeout = "3000ms"

	port:               devshell.#Port | *defaultPort
	consolePort:        devshell.#Port | *defaultConsolePort
	dataDir:            string | *defaultDataDir
	timeout:            devshell.#Duration | *defaultTimeout
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
		port:      devshell.#Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/minio/health/live"
		timeout:   devshell.#Duration | *"1500ms"
		timeoutMs: int | *1500
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/minio/health/ready"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *3000
	}
}

#NginxService: devshell.#Service & {
	package: devshell.#PackageRef | *"nginx"

	let defaultPort = 8080
	let defaultConfigFile = "/etc/nginx/nginx.conf"
	let defaultRunDir = ".enve/data/nginx"
	let defaultTimeout = "2000ms"

	port:          devshell.#Port | *defaultPort
	configFile:    string | *defaultConfigFile
	runDir:        string | *defaultRunDir
	timeout:       devshell.#Duration | *defaultTimeout
	timeoutMs:     int | *2000
	command:       string | *"nginx -p \(runDir) -c \(configFile) -g 'daemon off;'"
	let servicePort = port
	healthCheck: {
		port:      devshell.#Port | *servicePort
		timeout:   devshell.#Duration | *"1000ms"
		timeoutMs: int | *1000
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *2000
	}
}

#MySQLService: devshell.#Service & {
	package: devshell.#PackageRef | *"mysql80"

	let defaultPort = 3306
	let defaultDataDir = ".enve/data/mysql"
	let defaultTimeout = "3500ms"

	port:        devshell.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     devshell.#Duration | *defaultTimeout
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
		port:      devshell.#Port | *servicePort
		timeout:   devshell.#Duration | *"1500ms"
		timeoutMs: int | *1500
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		command:   string | *"mysqladmin ping -h 127.0.0.1 -P \(servicePort)"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *3500
	}
}

#ClickHouseService: devshell.#Service & {
	package: devshell.#PackageRef | *"clickhouse"

	let defaultHttpPort = 8123
	let defaultTcpPort = 9000
	let defaultDataDir = ".enve/data/clickhouse"
	let defaultConfigFile = ".enve/config/clickhouse/config.xml"
	let defaultTimeout = "3500ms"

	port:        devshell.#Port | *defaultHttpPort
	tcpPort:     devshell.#Port | *defaultTcpPort
	dataDir:     string | *defaultDataDir
	configFile:  string | *defaultConfigFile
	timeout:     devshell.#Duration | *defaultTimeout
	timeoutMs:   int | *3500
	command:     string | *"clickhouse-server --config-file=\(defaultConfigFile)"
	environment: {
		CLICKHOUSE_DATA_DIR:  defaultDataDir
		CLICKHOUSE_HTTP_PORT: "\(defaultHttpPort)"
		CLICKHOUSE_TCP_PORT:  "\(defaultTcpPort)"
	}
	let servicePort = port
	healthCheck: {
		port:      devshell.#Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/ping"
		timeout:   devshell.#Duration | *"1000ms"
		timeoutMs: int | *1000
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		command:   string | *"curl -s -f 'http://127.0.0.1:\(servicePort)/?query=SELECT+1'"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *3500
	}
}

#TemporalService: devshell.#Service & {
	package: devshell.#PackageRef | *"temporal-cli"

	let defaultPort = 7233
	let defaultDataDir = ".enve/data/temporal"
	let defaultDbFilename = ".enve/data/temporal/temporal.db"
	let defaultTimeout = "2500ms"

	port:        devshell.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	dbFilename:  string | *defaultDbFilename
	timeout:     devshell.#Duration | *defaultTimeout
	timeoutMs:   int | *2500
	command:     string | *"temporal server start-dev --port \(port) --headless --db-filename \(dbFilename)"
	environment: {
		TEMPORAL_PORT: "\(port)"
		TEMPORAL_HOST: "127.0.0.1"
	}
	let servicePort = port
	healthCheck: {
		port:      devshell.#Port | *servicePort
		timeout:   devshell.#Duration | *"1000ms"
		timeoutMs: int | *1000
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		command:   string | *"temporal operator cluster health --address 127.0.0.1:\(servicePort)"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *2500
	}
}

#SeaweedfsService: devshell.#Service & {
	package: devshell.#PackageRef | *"seaweedfs"

	let defaultPort = 19000
	let defaultDataDir = ".enve/data/seaweedfs"
	let defaultTimeout = "6000ms"

	port:        devshell.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     devshell.#Duration | *defaultTimeout
	timeoutMs:   int | *6000
	command:     string | *"weed server -s3 -s3.port=\(port) -dir=\(dataDir)"
	environment: {
		S3_PORT:     "\(port)"
		S3_ENDPOINT: "http://127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      devshell.#Port | *servicePort
		timeout:   devshell.#Duration | *"4000ms"
		timeoutMs: int | *4000
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		command:   string | *"curl -s -f -o /dev/null http://127.0.0.1:\(servicePort)/"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *6000
	}
}

#RedpandaService: devshell.#Service & {
	package: devshell.#PackageRef | *"redpanda"

	let defaultKafkaPort = 9092
	let defaultAdminPort = 9644
	let defaultDataDir = ".enve/data/redpanda"
	let defaultTimeout = "4000ms"

	port:        devshell.#Port | *defaultKafkaPort
	adminPort:   devshell.#Port | *defaultAdminPort
	dataDir:     string | *defaultDataDir
	timeout:     devshell.#Duration | *defaultTimeout
	timeoutMs:   int | *4000
	command:     string | *"redpanda start --mode dev-container --kafka-addr 127.0.0.1:\(port) --admin-addr 127.0.0.1:\(adminPort) --dir \(dataDir) --smp 1 --memory 512M --reserve-memory 0M --check=false"
	environment: {
		KAFKA_PORT:     "\(port)"
		KAFKA_BROKERS:  "127.0.0.1:\(port)"
		REDPANDA_ADMIN: "127.0.0.1:\(adminPort)"
	}
	let servicePort = port
	healthCheck: {
		port:      devshell.#Port | *servicePort
		timeout:   devshell.#Duration | *"1500ms"
		timeoutMs: int | *1500
	}
	readinessProbe: {
		port:      devshell.#Port | *adminPort
		path:      string | *"http://127.0.0.1:\(adminPort)/v1/cluster/ready"
		timeout:   devshell.#Duration | *defaultTimeout
		timeoutMs: int | *4000
	}
}

#TansuService: devshell.#Service & {
	package: devshell.#PackageRef | *"tansu"

	let defaultPort = 9092
	let defaultEngine = "memory://tansu/"
	let defaultTimeout = "1500ms"

	port:          devshell.#Port | *defaultPort
	storageEngine: string | *defaultEngine
	timeout:       devshell.#Duration | *defaultTimeout
	timeoutMs:     int | *1500
	command:       string | *"tansu --listener-url tcp://127.0.0.1:\(port) --advertised-listener-url tcp://127.0.0.1:\(port) --storage-engine \(storageEngine)"
	environment: {
		KAFKA_PORT:    "\(port)"
		KAFKA_BROKERS: "127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      devshell.#Port | *servicePort
		timeout:   devshell.#Duration | *"800ms"
		timeoutMs: int | *800
	}
	readinessProbe: {
		port:      devshell.#Port | *servicePort
		timeout:   devshell.#Duration | *"1000ms"
		timeoutMs: int | *1000
	}
}

#KafkaService: #TansuService

