package devshell

import (
	"github.com/tonky/enve/pkgs:pkgs"
	schema "github.com/tonky/enve/schema/v1:schema"
)

// PostHog Analytics Polyglot Monorepo
// Zero-Daemon Rootless Developer Environment & Microservice Topology
profiles: dev: schema.#Profile & {
	name:        "posthog-monorepo"
	description: "PostHog Polyglot Monorepo (Django + ClickHouse + Kafka + Temporal + SeaweedFS)"

	tools: [
		pkgs.python313,
		pkgs.uv,
		pkgs.clickhouse,
		pkgs.postgresql_16,
		pkgs.redis,
		pkgs.temporal,
		pkgs.tansu,
		pkgs.seaweedfs,
		{pname: "sqlx-cli"},
	]

	environment: {
		DATABASE_URL:                      "postgres://posthog:posthog@127.0.0.1:15432/posthog"
		DAGSTER_TEST_POSTGRES_URL:         "postgresql://posthog:posthog@127.0.0.1:15432/test_dagster"
		PGPORT:                            "15432"
		REDIS_URL:                         "redis://127.0.0.1:16379"
		REDIS_PORT:                        "16379"
		CLICKHOUSE_HOST:                   "127.0.0.1"
		CLICKHOUSE_HTTP_PORT:              "8123"
		CLICKHOUSE_TCP_PORT:               "9000"
		CLICKHOUSE_POSTGRES_HOST:          "127.0.0.1"
		CLICKHOUSE_POSTGRES_PORT:          "15432"
		CLICKHOUSE_DATABASE:               "test_posthog"
		PERSON_ON_EVENTS_V2_ENABLED:       "true"
		KAFKA_HOSTS:                       "127.0.0.1:19092"
		TEMPORAL_HOST:                     "127.0.0.1"
		TEMPORAL_PORT:                     "7233"
		CAPTURE_PORT:                      "18000"
		OBJECT_STORAGE_ENABLED:            "True"
		OBJECT_STORAGE_ENDPOINT:           "http://127.0.0.1:19000"
		OBJECT_STORAGE_ACCESS_KEY_ID:      "object_storage_root_user"
		OBJECT_STORAGE_SECRET_ACCESS_KEY:  "object_storage_root_password"
		NOTEBOOKS_FRAME_STORE_S3_ENDPOINT: "http://127.0.0.1:19000"
		DEBUG:                             "true"
		TEST:                              "true"
		PGHOST:                            "127.0.0.1"
		PGUSER:                            "posthog"
		PGDATABASE:                        "posthog"
		SECRET_KEY:                        "showcase_secret_key"
		DJANGO_SECRET_KEY:                 "showcase_secret_key"
		INTERNAL_API_SECRET:               "ci-boot-test-dummy-secret"
		SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
		MALLOC_ARENA_MAX:                  "2"
		OMP_NUM_THREADS:                   "1"
		OPENBLAS_NUM_THREADS:              "1"
		MKL_NUM_THREADS:                   "1"
		POLARS_MAX_THREADS:                "1"
		RAYON_NUM_THREADS:                 "1"
		NUMEXPR_NUM_THREADS:               "1"
		VECLIB_MAXIMUM_THREADS:            "1"
	}

	services: {
		postgres: {
			name:     "postgres"
			database: "posthog"
			user:     "posthog"
			command:  "postgres -D /tmp/posthog_pg_15432 -h 127.0.0.1 -p 15432 -k /tmp -c listen_addresses=127.0.0.1 -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c wal_level=minimal"
			port:     15432
			dataDir:  "/tmp/posthog_pg_15432"
			environment: {
				DATA_DIR:     "/tmp/posthog_pg_15432"
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				PGHOST:       "127.0.0.1"
				PGUSER:       "posthog"
				PGDATABASE:   "posthog"
			}
			lifecycle: {
				init: [
					"sh -c 'test -f /tmp/posthog_pg_15432/PG_VERSION || { initdb -D /tmp/posthog_pg_15432 --auth=trust --username=posthog --no-sync && printf \"CREATE ROLE postgres SUPERUSER LOGIN;\\nCREATE DATABASE posthog;\\nCREATE DATABASE test_posthog;\\nCREATE DATABASE test_posthog_persons;\\n\" | postgres --single -D /tmp/posthog_pg_15432 template1; }'",
				]
				postStart: [
					"sh -c 'test -f scripts/prime_database.sh && bash scripts/prime_database.sh || bash showcase/scripts/prime_database.sh'",
				]
			}
			readinessProbe: {
				port:    15432
				timeout: "5s"
			}
		}

		redis: {
			name:    "redis"
			command: "redis-server --port 16379 --dir /tmp/posthog_redis_16379 --save '' --appendonly no"
			port:    16379
			lifecycle: init: [
				"mkdir -p /tmp/posthog_redis_16379",
			]
			readinessProbe: {
				port:    16379
				timeout: "3s"
			}
		}

		kafka: {
			name:    "kafka"
			command: "tansu --listener-url tcp://127.0.0.1:19092 --advertised-listener-url tcp://127.0.0.1:19092 --storage-engine memory://tansu/"
			port:    19092
			lifecycle: postStart: [
				"sh -c 'test -f scripts/create_test_kafka_topics.py && python scripts/create_test_kafka_topics.py 127.0.0.1:19092 || python showcase/scripts/create_test_kafka_topics.py 127.0.0.1:19092 || true'",
			]
			readinessProbe: {
				port:    19092
				timeout: "3s"
			}
		}

		clickhouse: {
			name:      "clickhouse"
			command:   "clickhouse-server --config-file config/clickhouse.xml"
			port:      8123
			dependsOn: [kafka]
			environment: {
				CLICKHOUSE_DATA_DIR:            "/tmp/clickhouse/data/"
				CLICKHOUSE_TMP_DIR:             "/tmp/clickhouse/tmp/"
				CLICKHOUSE_USER_FILES_DIR:      "/tmp/clickhouse/user_files/"
				CLICKHOUSE_FORMAT_SCHEMA_DIR:   "/tmp/clickhouse/format_schemas/"
				CLICKHOUSE_ACCESS_DIR:          "/tmp/clickhouse/access/"
				CLICKHOUSE_KEEPER_LOG_DIR:      "/tmp/clickhouse/keeper/log/"
				CLICKHOUSE_KEEPER_SNAPSHOT_DIR: "/tmp/clickhouse/keeper/snapshots/"
				CLICKHOUSE_USER_SCRIPTS_DIR:    "/tmp/clickhouse/data/user_scripts/"
				KAFKA_HOSTS:                    "127.0.0.1:19092"
			}
			lifecycle: {
				init: [
					"mkdir -p /tmp/clickhouse/data /tmp/clickhouse/tmp /tmp/clickhouse/user_files /tmp/clickhouse/format_schemas /tmp/clickhouse/access /tmp/clickhouse/keeper/log /tmp/clickhouse/keeper/snapshots && sh -c 'test -d posthog/user_scripts && US_DIR=\"$(pwd)/posthog/user_scripts\" || US_DIR=\"$(pwd)/../posthog/user_scripts\"; ln -sfn \"$US_DIR\" /tmp/clickhouse/data/user_scripts; mkdir -p /dev/shm/clickhouse/data && ln -sfn \"$US_DIR\" /dev/shm/clickhouse/data/user_scripts || true'",
				]
				postStart: [
					"curl -s --data-binary 'CREATE DATABASE IF NOT EXISTS posthog_test' http://127.0.0.1:8123/",
					"curl -s --data-binary 'CREATE DATABASE IF NOT EXISTS test_posthog' http://127.0.0.1:8123/",
				]
			}
			healthCheck: {
				port:    8123
				path:    "http://127.0.0.1:8123/ping"
				timeout: "10s"
			}
			readinessProbe: {
				port:    8123
				timeout: "10s"
			}
		}

		temporal: {
			name:    "temporal"
			command: "temporal server start-dev --ip 127.0.0.1 --port 7233 --headless"
			port:    7233
			readinessProbe: {
				port:    7233
				timeout: "5s"
			}
		}

		objectstorage: {
			name:    "objectstorage"
			command: "weed mini -ip=127.0.0.1 -ip.bind=127.0.0.1 -dir=/tmp/posthog_s3_19000 -s3.port=19000 -bucket=posthog,test-posthog,posthog-recordings,test-recordings"
			port:    19000
			lifecycle: init: [
				"mkdir -p /tmp/posthog_s3_19000",
			]
			environment: {
				AWS_ACCESS_KEY_ID:     "object_storage_root_user"
				AWS_SECRET_ACCESS_KEY: "object_storage_root_password"
				S3_BUCKET:             "posthog,test-posthog,posthog-recordings,test-recordings"
			}
			readinessProbe: {
				port:    19000
				timeout: "5s"
			}
		}

		app: {
			name:      "app"
			directory: ".."
			dependsOn: [postgres, redis, kafka, clickhouse]
			environment: {
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				PGHOST:       "127.0.0.1"
				PGUSER:       "posthog"
				PGDATABASE:   "posthog"
				PGPORT:       "15432"
			}
			test: "uv run pytest posthog/api/test/test_event.py --reuse-db -p no:icdiff -m 'not async_migrations' -W 'ignore:pkg_resources is deprecated:UserWarning' -W 'ignore::UserWarning:infi.clickhouse_orm'"
		}
	}

	shellHook: """
		echo "Welcome to PostHog Monorepo (Zero-Daemon enve environment)"
		echo "Run 'enve up' to start background microservices in <1.2s"
		echo "Run 'enve up postgres redis' for minimal web API hacking"
		"""
}
