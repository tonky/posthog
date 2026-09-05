package devshell

// PostHog Analytics Polyglot Monorepo
// Zero-Daemon Rootless Developer Environment & Microservice Topology
devEnv: {
	name:        "posthog-monorepo"
	description: "PostHog Polyglot Monorepo (Django + Rust Capture + ClickHouse + Kafka + Temporal)"

	tools: [
		"python311",
		"uv",
		"rust",
		"cargo",
		"clickhouse",
		"postgresql",
		"redis",
		"redpanda",
		"temporal",
	]

	environment: {
		DATABASE_URL:              "postgres://posthog@127.0.0.1:15432/posthog"
		DAGSTER_TEST_POSTGRES_URL: "postgresql://posthog@127.0.0.1:15432/test_dagster"
		PGPORT:                    "15432"
		REDIS_URL:            "redis://127.0.0.1:16379"
		REDIS_PORT:           "16379"
		CLICKHOUSE_HOST:      "127.0.0.1"
		CLICKHOUSE_HTTP_PORT: "18123"
		CLICKHOUSE_TCP_PORT:  "19000"
		KAFKA_HOSTS:          "127.0.0.1:19092"
		TEMPORAL_HOST:        "127.0.0.1:17233"
		CAPTURE_PORT:         "18000"
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
			command: "temporal server start-dev --port 17233 --headless"
			port:    17233
			readinessProbe: {
				port:      17233
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
	}

	shellHook: """
		echo "🦔 Welcome to PostHog Monorepo (Zero-Daemon enve environment)"
		echo "Run 'enve up' to start background microservices in <1.2s"
		echo "Run 'enve up postgres redis' for minimal web API hacking"
		"""
}
