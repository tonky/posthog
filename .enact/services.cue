package replay

import "enact.dev/schema"

// Kinds of the enve services components reach through `uses`: enact derives connection
// variables, readiness checks and database forking from them.
pipeline: schema.#Pipeline & {
	services: {
		postgres: {
			name:  "postgres"
			enact: kind: schema.#ServiceKind.Postgres
		}
		redis: {
			name:  "redis"
			enact: kind: schema.#ServiceKind.Redis
		}
		clickhouse: {
			name:  "clickhouse"
			enact: kind: schema.#ServiceKind.ClickHouse
		}
		kafka: {
			name:  "kafka"
			enact: kind: schema.#ServiceKind.Kafka
		}
		seaweedfs: {
			name:  "seaweedfs"
			enact: kind: schema.#ServiceKind.ObjectStorage
		}
		temporal: {
			name:  "temporal"
			enact: kind: schema.#ServiceKind.Temporal
		}
		// The coordination store the personhog and kafka-assigner tests use: no kind of enact's.
		etcd: name: "etcd"
		// A cluster-enabled Redis (one node, every slot): no kind of enact's, whose Redis kind
		// numbers a database per shard, which a cluster has one of.
		"valkey-cluster": name: "valkey-cluster"
		// Azure's blob storage, emulated: no kind of enact's (it derives nothing from it).
		azurite: name: "azurite"
	}
}
