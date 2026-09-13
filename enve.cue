package devshell

import (
	schema "github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// PostHog Analytics Polyglot Monorepo
// Zero-Daemon Rootless Developer Environment & Microservice Topology
// Functional Parity with Flox + Docker Compose + mprocs
devEnv: schema.#DevEnvironment & {
	name:        "posthog-monorepo"
	description: "PostHog Polyglot Monorepo (Django + Vite + Node Ingestion + Rust Services + Go AI Gateway + ClickHouse + Kafka + Temporal + SeaweedFS)"

	tools: [
		// Core Databases & Infrastructure
		pkgs.postgres,
		"redis",
		"clickhouse",
		pkgs.temporal,
		pkgs.seaweedfs,
		pkgs.tansu,

		// Runtimes & Compilers
		"uv",
		"nodejs",
		"rustc",
		"cargo",
		"clippy",
		"rustfmt",
		"go",
		"golangci-lint",

		// Developer CLI Tools
		"ripgrep",
		"jq",
		"just",
		"watchexec",
	]

	hosts: {
		"db":            "127.0.0.1"
		"redis7":        "127.0.0.1"
		"clickhouse":    "127.0.0.1"
		"kafka":         "127.0.0.1"
		"objectstorage": "127.0.0.1"
		"temporal":      "127.0.0.1"
	}

	environment: {
		DEBUG:                             "0"
		DATABASE_URL:                      "postgres://posthog:posthog@127.0.0.1:15432/posthog"
		PERSONS_DATABASE_URL:              "postgres://posthog:posthog@127.0.0.1:15432/posthog"
		DAGSTER_TEST_POSTGRES_URL:         "postgresql://posthog:posthog@127.0.0.1:15432/test_dagster"
		PGPORT:                            "15432"
		PGHOST:                            "127.0.0.1"
		REDIS_URL:                         "redis://127.0.0.1:16379"
		FLAGS_REDIS_URL:                   "redis://127.0.0.1:16379/1"
		REDIS_PORT:                        "16379"
		CLICKHOUSE_HOST:                   "127.0.0.1"
		CLICKHOUSE_DATABASE:               "posthog"
		CLICKHOUSE_HTTP_PORT:              "8123"
		CLICKHOUSE_TCP_PORT:               "9000"
		CLICKHOUSE_POSTGRES_HOST:          "127.0.0.1"
		CLICKHOUSE_POSTGRES_PORT:          "15432"
		PERSON_ON_EVENTS_V2_ENABLED:       "true"
		KAFKA_HOSTS:                       "127.0.0.1:19092"
		KAFKA_URL:                         "127.0.0.1:19092"
		TEMPORAL_HOST:                     "127.0.0.1"
		TEMPORAL_PORT:                     "7233"
		TEMPORAL_ADDRESS:                  "127.0.0.1:7233"
		CAPTURE_PORT:                      "3000"
		OBJECT_STORAGE_ENABLED:            "True"
		OBJECT_STORAGE_ENDPOINT:           "http://127.0.0.1:19000"
		OBJECT_STORAGE_ACCESS_KEY_ID:      "object_storage_root_user"
		OBJECT_STORAGE_SECRET_ACCESS_KEY:  "object_storage_root_password"
		NOTEBOOKS_FRAME_STORE_S3_ENDPOINT: "http://127.0.0.1:19000"
	}

	services: {
		// ====================================================================
		// INFRASTRUCTURE SERVICES (Rootless, zero-Docker)
		// ====================================================================

		// 1. PostgreSQL Relational Database (Port 15432)
		postgres: pkgs.#PostgresService & {
			port:      15432
			dataDir:   ".enve/data/postgres"
			database:  "posthog"
			user:      "posthog"
			timeoutMs: 5000

			command: "postgres -D .enve/data/postgres -k /tmp -p 15432 -c fsync=off -c synchronous_commit=off"

			lifecycle: {
				init: [
					"sh -c 'test -f .enve/data/postgres/PG_VERSION || initdb -D .enve/data/postgres -U posthog --auth-local=trust --auth-host=trust --no-sync'",
				]
				postStart: [
					"psql -h 127.0.0.1 -p 15432 -U posthog -d postgres -c 'CREATE ROLE postgres SUPERUSER LOGIN;' || true",
					"psql -h 127.0.0.1 -p 15432 -U posthog -d postgres -c 'CREATE DATABASE posthog;' || true",
					"psql -h 127.0.0.1 -p 15432 -U posthog -d postgres -c 'CREATE DATABASE test_posthog;' || true",
					"psql -h 127.0.0.1 -p 15432 -U posthog -d postgres -c 'CREATE DATABASE test_posthog_persons;' || true",
					"sh -c 'if [ -f showcase/snapshots/test_posthog.sql.gz ]; then count=$(psql -h 127.0.0.1 -p 15432 -U posthog -d test_posthog -tAc \"SELECT count(*) FROM django_migrations\" 2>/dev/null || echo 0); if [ \"$count\" -lt 2000 ]; then gunzip -c showcase/snapshots/test_posthog.sql.gz | psql -h 127.0.0.1 -p 15432 -U posthog -q -d test_posthog || true; fi; fi'",
					"sh -c 'if [ -f showcase/snapshots/test_posthog_persons.sql.gz ]; then count=$(psql -h 127.0.0.1 -p 15432 -U posthog -d test_posthog_persons -tAc \"SELECT count(*) FROM information_schema.tables WHERE table_schema=\\\"public\\\"\" 2>/dev/null || echo 0); if [ \"$count\" -lt 5 ]; then gunzip -c showcase/snapshots/test_posthog_persons.sql.gz | psql -h 127.0.0.1 -p 15432 -U posthog -q -d test_posthog_persons || true; fi; fi'",
				]
			}

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      15432
				command:   "pg_isready -h 127.0.0.1 -p 15432 -U posthog"
				timeoutMs: 2000
			}

			readinessProbe: {
				port:      15432
				command:   "psql -h 127.0.0.1 -p 15432 -U posthog -d postgres -c 'SELECT 1;'"
				timeoutMs: 5000
			}
		}

		// 2. Redis In-Memory Store (Port 16379)
		redis: pkgs.#RedisService & {
			port:      16379
			dataDir:   ".enve/data/redis"
			timeoutMs: 3000

			command: "redis-server --port 16379 --dir .enve/data/redis --save '' --appendonly no --daemonize no"

			lifecycle: init: [
				"mkdir -p .enve/data/redis",
			]

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      16379
				timeoutMs: 1000
			}

			readinessProbe: {
				port:      16379
				command:   "redis-cli -p 16379 ping"
				timeoutMs: 3000
			}
		}

		// 3. ClickHouse Analytical DBMS (Port 8123 HTTP / 9000 TCP)
		clickhouse: pkgs.#ClickHouseService & {
			port:      8123
			tcpPort:   9000
			dataDir:   ".enve/data/clickhouse"
			dependsOn: ["kafka"]
			timeout:   "15000ms"
			timeoutMs: 15000

			command: "clickhouse-server --config-file showcase/config/clickhouse.xml"

			environment: {
				CLICKHOUSE_USER_SCRIPTS_DIR:    ".enve/data/clickhouse/user_scripts/"
				CLICKHOUSE_UDF_CONFIG:          "user_defined_function.xml"
				CLICKHOUSE_TMP_DIR:             ".enve/data/clickhouse/tmp/"
				CLICKHOUSE_USER_FILES_DIR:      ".enve/data/clickhouse/user_files/"
				CLICKHOUSE_FORMAT_SCHEMA_DIR:   ".enve/data/clickhouse/format_schemas/"
				CLICKHOUSE_ACCESS_DIR:          ".enve/data/clickhouse/access/"
				CLICKHOUSE_KEEPER_LOG_DIR:      ".enve/data/clickhouse/keeper/log/"
				CLICKHOUSE_KEEPER_SNAPSHOT_DIR: ".enve/data/clickhouse/keeper/snapshots/"
				KAFKA_HOSTS:                    "127.0.0.1:19092"
			}

			lifecycle: init: [
				"mkdir -p .enve/data/clickhouse/tmp .enve/data/clickhouse/user_files .enve/data/clickhouse/format_schemas .enve/data/clickhouse/access .enve/data/clickhouse/keeper/log .enve/data/clickhouse/keeper/snapshots && ln -sf $(git rev-parse --show-toplevel)/posthog/user_scripts .enve/data/clickhouse/user_scripts",
			]

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      8123
				path:      "http://127.0.0.1:8123/ping"
				timeout:   "15000ms"
				timeoutMs: 15000
			}

			readinessProbe: {
				port:      8123
				command:   "curl -s -f 'http://127.0.0.1:8123/?query=SELECT+1'"
				timeout:   "15000ms"
				timeoutMs: 15000
			}
		}

		// 4. Kafka Streaming Broker via Tansu (Port 19092)
		kafka: pkgs.#TansuService & {
			port:          19092
			storageEngine: "memory://tansu/"
			timeoutMs:     3000

			command: "tansu --listener-url tcp://127.0.0.1:19092 --advertised-listener-url tcp://127.0.0.1:19092 --storage-engine memory://tansu/"

			lifecycle: postStart: [
				".venv/bin/python showcase/scripts/create_test_kafka_topics.py || true",
			]

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      19092
				timeoutMs: 1000
			}

			readinessProbe: {
				port:      19092
				timeoutMs: 3000
			}
		}

		// 5. Temporal Workflow Engine (Port 7233)
		temporal: pkgs.#TemporalService & {
			port:       7233
			dataDir:    ".enve/data/temporal"
			dbFilename: ".enve/data/temporal/temporal.db"
			timeoutMs:  5000

			command: "temporal server start-dev --port 7233 --ip 127.0.0.1 --headless --db-filename .enve/data/temporal/temporal.db"

			lifecycle: init: [
				"mkdir -p .enve/data/temporal",
			]

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      7233
				timeoutMs: 2000
			}

			readinessProbe: {
				port:      7233
				command:   "temporal operator cluster health --address 127.0.0.1:7233"
				timeoutMs: 5000
			}
		}

		// 6. SeaweedFS S3 Object Storage (Port 19000)
		seaweedfs: pkgs.#SeaweedfsService & {
			port:      19000
			dataDir:   ".enve/data/seaweedfs"
			timeoutMs: 6000

			command: "weed mini -ip=127.0.0.1 -ip.bind=127.0.0.1 -dir=.enve/data/seaweedfs -s3.port=19000 -bucket=posthog,test-posthog,posthog-recordings,test-recordings,ai-blobs"

			environment: {
				AWS_ACCESS_KEY_ID:     "object_storage_root_user"
				AWS_SECRET_ACCESS_KEY: "object_storage_root_password"
				S3_BUCKET:             "posthog,test-posthog,posthog-recordings,test-recordings,ai-blobs"
			}

			lifecycle: init: [
				"mkdir -p .enve/data/seaweedfs",
			]

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      19000
				timeoutMs: 3000
			}

			readinessProbe: {
				port:      19000
				command:   "curl -s -o /dev/null http://127.0.0.1:19000/"
				timeoutMs: 6000
			}
		}

		// ====================================================================
		// APPLICATION & PRODUCT SERVICES (Full Parity with mprocs / Flox)
		// ====================================================================

		// 7. PostHog Backend (Django ASGI via Granian on Port 8000)
		backend: schema.#Service & {
			command: ".venv/bin/python -m granian --interface asgi posthog.asgi:application --host 127.0.0.1 --port 8000 --reload --reload-paths ./posthog --reload-paths ./ee --reload-paths ./products"
			port:    8000
			dependsOn: ["postgres", "redis", "clickhouse"]
			timeoutMs: 30000

			environment: {
				DEBUG:                 "1"
				SECRET_KEY:            "posthog-enve-dev-key"
				DATABASE_URL:          "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				PERSONS_DB_WRITER_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:             "redis://127.0.0.1:16379"
				CLICKHOUSE_HOST:       "127.0.0.1"
				CLICKHOUSE_HTTP_PORT:  "8123"
				CLICKHOUSE_PORT:       "9000"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      8000
				path:      "http://127.0.0.1:8000/_health"
				timeoutMs: 60000
			}

			readinessProbe: {
				port:      8000
				path:      "http://127.0.0.1:8000/_health"
				timeoutMs: 60000
			}
		}

		// 8. Frontend Dev Server (Vite on Port 8234)
		frontend: schema.#Service & {
			command: "./bin/start-frontend"
			port:    8234
			dependsOn: ["backend"]
			timeoutMs: 60000

			environment: {
				DEBUG: "0"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      8234
				timeoutMs: 60000
			}

			readinessProbe: {
				port:      8234
				timeoutMs: 60000
			}
		}

		// 9. Celery Background Worker
		"celery-worker": schema.#Service & {
			command: "./bin/start-celery worker"
			dependsOn: ["postgres", "redis", "clickhouse"]
			timeoutMs: 30000

			environment: {
				DEBUG:        "1"
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:    "redis://127.0.0.1:16379"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 10. Celery Beat Periodic Scheduler
		"celery-beat": schema.#Service & {
			command: "./bin/start-celery beat"
			dependsOn: ["postgres", "redis", "celery-worker"]
			timeoutMs: 30000

			environment: {
				DEBUG:        "1"
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:    "redis://127.0.0.1:16379"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 11. Temporal Worker (Workflow & Activities Execution)
		"temporal-worker": schema.#Service & {
			command: "python manage.py start_temporal_worker --task-queue development-task-queue"
			dependsOn: ["temporal", "postgres", "redis"]
			timeoutMs: 45000

			environment: {
				TEMPORAL_HOST: "127.0.0.1"
				TEMPORAL_PORT: "7233"
				DATABASE_URL:  "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:     "redis://127.0.0.1:16379"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 12. PostHog Node Ingestion Server (Plugin Server - Combined Ingestion v2)
		ingestion: schema.#Service & {
			command: "PLUGIN_SERVER_MODE=ingestion-v2-combined HTTP_SERVER_PORT=6739 ./bin/posthog-node"
			port:    6739
			dependsOn: ["kafka", "postgres", "redis", "seaweedfs"]
			timeoutMs: 60000

			environment: {
				DATABASE_URL:                 "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				PERSONS_DATABASE_URL:         "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:                    "redis://127.0.0.1:16379"
				KAFKA_HOSTS:                  "127.0.0.1:19092"
				CLICKHOUSE_HOST:              "127.0.0.1"
				CLICKHOUSE_PORT:              "8123"
				AI_BLOB_S3_BUCKET:            "ai-blobs"
				AI_BLOB_S3_ENDPOINT:          "http://127.0.0.1:19000"
				AI_BLOB_S3_ACCESS_KEY_ID:     "object_storage_root_user"
				AI_BLOB_S3_SECRET_ACCESS_KEY: "object_storage_root_password"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      6739
				timeoutMs: 60000
			}

			readinessProbe: {
				port:      6739
				timeoutMs: 60000
			}
		}

		// 13. Session Replay Ingestion (Blob Ingestion v2)
		"ingestion-sessionreplay": schema.#Service & {
			command: "PLUGIN_SERVER_MODE=recordings-blob-ingestion-v2 HTTP_SERVER_PORT=6740 ./bin/posthog-node"
			port:    6740
			dependsOn: ["kafka", "seaweedfs", "postgres", "redis"]
			timeoutMs: 60000

			environment: {
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:    "redis://127.0.0.1:16379"
				KAFKA_HOSTS:  "127.0.0.1:19092"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 14. PostHog Capture Gateway (Rust on Port 3000)
		capture: schema.#Service & {
			command: "cargo run --manifest-path rust/capture/Cargo.toml"
			port:    3000
			dependsOn: ["postgres", "redis", "kafka"]
			timeoutMs: 60000

			environment: {
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:    "redis://127.0.0.1:16379"
				KAFKA_HOSTS:  "127.0.0.1:19092"
				ADDRESS:      "127.0.0.1:3000"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure

			healthCheck: {
				port:      3000
				path:      "http://127.0.0.1:3000/_liveness"
				timeoutMs: 60000
			}

			readinessProbe: {
				port:      3000
				path:      "http://127.0.0.1:3000/_readiness"
				timeoutMs: 60000
			}
		}

		// 15. Rust Feature Flags Service (Port 3001)
		"feature-flags": schema.#Service & {
			command: "bin/start-rust-service feature-flags"
			port:    3001
			dependsOn: ["redis", "postgres"]
			timeoutMs: 60000

			environment: {
				BIND_PORT:    "3001"
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:    "redis://127.0.0.1:16379"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 16. Rust Hypercache Server (Surveys & Remote Config Proxy on Port 3002)
		"hypercache-server": schema.#Service & {
			command: "bin/start-rust-service hypercache-server"
			port:    3002
			dependsOn: ["redis"]
			timeoutMs: 30000

			environment: {
				REDIS_URL: "redis://127.0.0.1:16379"
				ADDRESS:   "127.0.0.1:3002"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 17. Rust Capture for Replay (/s/ recordings on Port 3306)
		"capture-replay": schema.#Service & {
			command: "bin/start-rust-service capture-replay"
			port:    3306
			dependsOn: ["kafka", "redis", "postgres"]
			timeoutMs: 60000

			environment: {
				ADDRESS:      "127.0.0.1:3306"
				KAFKA_HOSTS:  "127.0.0.1:19092"
				REDIS_URL:    "redis://127.0.0.1:16379"
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				CAPTURE_MODE: "recordings"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 18. Rust Capture for AI Analytics (/i/v0/ai on Port 3309)
		"capture-ai": schema.#Service & {
			command: "bin/start-rust-service capture-ai"
			port:    3309
			dependsOn: ["kafka", "redis", "postgres"]
			timeoutMs: 60000

			environment: {
				ADDRESS:      "127.0.0.1:3309"
				KAFKA_HOSTS:  "127.0.0.1:19092"
				REDIS_URL:    "redis://127.0.0.1:16379"
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				CAPTURE_MODE: "ai"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 19. Rust Cymbal - Error Tracking Symbolication Engine (Port 3302)
		cymbal: schema.#Service & {
			command: "bin/start-rust-service cymbal"
			port:    3302
			dependsOn: ["postgres", "redis", "seaweedfs"]
			timeoutMs: 60000

			environment: {
				BIND_PORT:                      "3302"
				CYMBAL_MODE:                    "processing"
				OBJECT_STORAGE_BUCKET:          "posthog"
				PERSONS_URL:                    "postgres://posthog:posthog@127.0.0.1:15432/test_posthog_persons"
				CYMBAL_REMOTE_RESOLUTION_HOST:  "127.0.0.1"
				CYMBAL_REMOTE_RESOLUTION_PORT:  "50061"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 20. Rust Cymbal Resolution - gRPC Sourcemap & Debug Symbol Resolver (Port 50061)
		"cymbal-resolution": schema.#Service & {
			command: "bin/start-rust-service cymbal-resolution"
			port:    50061
			dependsOn: ["postgres", "seaweedfs"]
			timeoutMs: 60000

			environment: {
				CYMBAL_MODE:            "resolution"
				GRPC_ADDRESS:           "127.0.0.1:50061"
				OBJECT_STORAGE_BUCKET:  "posthog"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 21. PersonHog Read Replica (Port 50051)
		"personhog-replica": schema.#Service & {
			command: "bin/start-rust-service personhog-replica"
			port:    50051
			dependsOn: ["postgres"]
			timeoutMs: 60000

			environment: {
				GRPC_ADDRESS:         "127.0.0.1:50051"
				PRIMARY_DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/test_posthog_persons"
				METRICS_PORT:         "9100"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 22. PersonHog Router (Port 50052)
		"personhog-router": schema.#Service & {
			command: "bin/start-rust-service personhog-router"
			port:    50052
			dependsOn: ["personhog-replica"]
			timeoutMs: 60000

			environment: {
				GRPC_ADDRESS: "127.0.0.1:50052"
				REPLICA_URL:  "http://127.0.0.1:50051"
				METRICS_PORT: "9101"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 23. Node.js Error Tracking Ingestion (Port 6742)
		"ingestion-errortracking": schema.#Service & {
			command: "PLUGIN_SERVER_MODE=ingestion-errortracking HTTP_SERVER_PORT=6742 ./bin/posthog-node"
			port:    6742
			dependsOn: ["kafka", "postgres", "redis"]
			timeoutMs: 60000

			environment: {
				DATABASE_URL: "postgres://posthog:posthog@127.0.0.1:15432/posthog"
				REDIS_URL:    "redis://127.0.0.1:16379"
				KAFKA_HOSTS:  "127.0.0.1:19092"
			}

			restartPolicy: schema.#RestartPolicy.OnFailure
		}

		// 24. Stripe Mock Billing API Server (Port 8443)
		"stripe-mock": schema.#Service & {
			command: "bin/start-stripe-mock"
			port:    8443
			timeoutMs: 30000
			restartPolicy: schema.#RestartPolicy.OnFailure
		}
	}

	shellHook: """
		echo "🦔 Welcome to PostHog Monorepo (Zero-Daemon enve environment)"
		echo "• Fast test impact runs: just test-affected"
		echo "• Start core infra     : enve up postgres redis clickhouse kafka seaweedfs temporal"
		echo "• Start web app stack  : just web-up"
		echo "• Start error tracking : enve up cymbal cymbal-resolution ingestion-errortracking"
		echo "• Start person identity: enve up personhog-replica personhog-router"
		echo "• Start full monorepo  : just stack-up"
		"""
}
