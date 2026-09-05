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

// -------------------------------------------------------------
// High-Level Microservice & Daemon Presets (#Service presets)
// -------------------------------------------------------------

#PostgresService: devshell.#Service & {
	let srvPort = 5432
	port: srvPort
	let dataDir = ".enve/data/postgres"
	command: "postgres -D \(dataDir) -k /tmp -p \(srvPort)"
	environment: {
		PGDATA:       dataDir
		PGPORT:       srvPort
		PGHOST:       "/tmp"
		DATABASE_URL: "postgresql://postgres@localhost:\(srvPort)/postgres"
	}
	readinessProbe: {
		port:      srvPort
		timeoutMs: 5000
	}
}

#RedisService: devshell.#Service & {
	let srvPort = 6379
	port: srvPort
	let dataDir = ".enve/data/redis"
	command: "redis-server --port \(srvPort) --dir \(dataDir) --daemonize no"
	environment: {
		REDIS_PORT: srvPort
		REDIS_URL:  "redis://localhost:\(srvPort)/0"
	}
	readinessProbe: {
		port:      srvPort
		timeoutMs: 3000
	}
}

#MinioService: devshell.#Service & {
	let srvPort = 9000
	port: srvPort
	let consolePort = 9001
	let dataDir = ".enve/data/minio"
	command: "minio server \(dataDir) --address :\(srvPort) --console-address :\(consolePort)"
	environment: {
		MINIO_PORT:          srvPort
		MINIO_CONSOLE_PORT:  consolePort
		MINIO_ROOT_USER:     "minioadmin"
		MINIO_ROOT_PASSWORD: "minioadmin"
		S3_ENDPOINT:         "http://localhost:\(srvPort)"
	}
	readinessProbe: {
		port:      srvPort
		timeoutMs: 5000
	}
}

#NginxService: devshell.#Service & {
	let srvPort = 8080
	port: srvPort
	let srvConfigFile = "/etc/nginx/nginx.conf"
	let runDir = ".enve/data/nginx"
	command: "nginx -p \(runDir) -c \(srvConfigFile) -g 'daemon off;'"
	readinessProbe: {
		port:      srvPort
		timeoutMs: 3000
	}
}

#MySQLService: devshell.#Service & {
	let srvPort = 3306
	port: srvPort
	let dataDir = ".enve/data/mysql"
	command: "mysqld --datadir=\(dataDir) --port=\(srvPort)"
	environment: {
		MYSQL_TCP_PORT: srvPort
	}
	readinessProbe: {
		port:      srvPort
		timeoutMs: 5000
	}
}
