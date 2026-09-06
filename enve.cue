package devshell

// PostHog Analytics Polyglot Monorepo
// Zero-Daemon Rootless Developer Environment & Microservice Topology
devEnv: {
	name:        "posthog-monorepo"
	description: "PostHog Polyglot Monorepo (Django + Rust Capture + ClickHouse + Kafka + Temporal)"

	tools: [
        "seaweedfs",
		"python311",
		"uv",
		"rust",
		"cargo",
		"clickhouse",
		"postgresql_15",
		"redis",
		"redpanda",
		"temporal",
	]

	environment: {
		DATABASE_URL:              "postgres://posthog@127.0.0.1:15432/posthog"
		DAGSTER_TEST_POSTGRES_URL: "postgresql://posthog@127.0.0.1:15432/test_dagster"
		PGPORT:                    "15432"
		REDIS_URL:                 "redis://127.0.0.1:16379"
		REDIS_PORT:                "16379"
		CLICKHOUSE_HOST:           "127.0.0.1"
		CLICKHOUSE_HTTP_PORT:      "8123"
		CLICKHOUSE_TCP_PORT:       "9000"
		KAFKA_HOSTS:               "127.0.0.1:19092"
		TEMPORAL_HOST:             "127.0.0.1"
		TEMPORAL_PORT:             "7233"
		CAPTURE_PORT:              "18000"
		OBJECT_STORAGE_ENABLED:            "True"
		OBJECT_STORAGE_ENDPOINT:           "http://127.0.0.1:19000"
		OBJECT_STORAGE_ACCESS_KEY_ID:      "object_storage_root_user"
		OBJECT_STORAGE_SECRET_ACCESS_KEY:  "object_storage_root_password"
		NOTEBOOKS_FRAME_STORE_S3_ENDPOINT: "http://127.0.0.1:19000"
	}

	services: {
		postgres: {
			name:    "postgres"
			command: "postgres -D data/postgres/data -p 15432"
			port:    15432
			readinessProbe: {
				port:      15432
				timeoutMs: 5000
			}
		}

		redis: {
			name:    "redis"
			command: "redis-server --port 16379 --save '' --appendonly no"
			port:    16379
			readinessProbe: {
				port:      16379
				timeoutMs: 3000
			}
		}

		clickhouse: {
			name:    "clickhouse"
			command: "clickhouse-server --config-file data/clickhouse/config.xml"
			port:    18123
			readinessProbe: {
				port:      18123
				timeoutMs: 5000
			}
		}

		redpanda: {
			name:    "redpanda"
			command: "redpanda --redpanda-cfg data/redpanda/conf/redpanda.yaml --smp 1 --memory 512M"
			port:    19092
			readinessProbe: {
				port:      19092
				timeoutMs: 5000
			}
		}

		temporal: {
			name:    "temporal"
			command: "temporal server start-dev --ip 127.0.0.1 --port 7233 --headless"
			port:    7233
			readinessProbe: {
				port:      7233
				timeoutMs: 5000
			}
		}

		capture: {
			name:      "capture"
			command:   "cargo run --manifest-path services/capture/Cargo.toml"
			port:      18000
			dependsOn: ["redis", "redpanda", "clickhouse"]
			readinessProbe: {
				port:      18000
				timeoutMs: 5000
			}
		}

		objectstorage: {
			name:    "objectstorage"
			command: "weed server -ip=127.0.0.1 -master.port=19001 -master.electionTimeout=1s -volume.port=19002 -filer.port=19003 -s3 -s3.port=19000 -dir=data/objectstorage -volume.max=1000 -master.volumePreallocate=false"
			port:    19000
			readinessProbe: {
				port:      19000
				timeoutMs: 15000
			}
		}
	}

	shellHook: """
		echo "🦔 Welcome to PostHog Monorepo (Zero-Daemon enve environment)"
		echo "Run 'enve up' to start background microservices in <1.2s"
		echo "Run 'enve up postgres redis' for minimal web API hacking"
		"""
}
