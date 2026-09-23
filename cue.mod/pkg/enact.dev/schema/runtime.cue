package schema

import "time"

// Accepts standard human-readable duration strings (e.g. "5s", "500ms", "1m") or integer milliseconds
#Duration: time.Duration | (int & > 0)

// Explicit lifecycle condition required before launching dependent service
#DependencyCondition: {
	Ready:   "ready"
	Healthy: "healthy"
	Started: "started"
}
#DependencyConditionMode: #DependencyCondition.Ready |
	#DependencyCondition.Healthy |
	#DependencyCondition.Started |
	*#DependencyCondition.Ready

// Strongly typed dependency descriptor
#ServiceDependency: {
	service:    _
	condition:  #DependencyConditionMode
	timeout?:   #Duration
	timeoutMs?: int & > 0
}

#DependencyRef: string | #ServiceDependency

// Hardware resource requirements
#ResourceSpec: {
	cpus?:      number // e.g. 2, 4, 8 cores
	memory_mb?: int    // e.g. 4096 (4GB), 16384 (16GB)
	shm_mb?:    int    // shared memory tmpfs size in MB
	gpu?:       bool | string // e.g. true or "nvidia-t4"
}

// Runner class / tier definition
#RunnerType: #RunnerKindMode

// Runner specification defining the execution environment and required capabilities.
#RunnerSpec: {
	type:       #RunnerKindMode   | *#RunnerKind.Auto
	target:     #RunnerTargetMode | *#RunnerTarget.Local
	platform:   #PlatformMode     | *#Platform.LinuxAmd64
	toolchain:  string // e.g. "go:1.22", "rust:1.85"
	resources?: #ResourceSpec
	external?: {
		labels?: [...string]
		tier?:   #RunnerTierMode  | *#RunnerTier.Standard
	}
}

#ServiceHealthCheck: {
	command?:        [...string] | string
	path?:           string // e.g. "/healthz"
	port?:           int
	interval?:       #Duration
	timeout?:        #Duration
	timeout_ms?:     int
	interval_ms?:    int
	retries?:        *3 | int
	restart_policy?: #RestartPolicyMode | *#RestartPolicy.OnFailure
}

#ServiceReadinessProbe: {
	command?:        [...string] | string
	path?:           string
	port?:           int
	initialDelay?:   #Duration
	timeout?:        #Duration
	timeout_ms?:     int
}

// Base daemonless microservice specification
#BaseService: {
	name?:            string
	external?:        bool | *false
	host?:            string | *"127.0.0.1"
	url?:             string
	directory?:       string
	watch?:           [...string]
	image?:           string
	command?:         string
	service_type?:    string
	protocol?:        string
	mode?:            #ServiceTransportMode
	placement?:       *#ServicePlacement.Shared | #ServicePlacement.Isolated | string
	socket_path?:     string
	port?:            int
	timeout?:         #Duration
	timeout_ms?:      int
	dependsOn?:       [...#DependencyRef] | {[string]: _}
	env?:             [string]: string
	health_check?:    #ServiceHealthCheck
	healthCheck?:     #ServiceHealthCheck
	readiness_probe?: #ServiceReadinessProbe
	readinessProbe?:  #ServiceReadinessProbe
	[string]:         _
}

#Service: #BaseService

// Strongly typed PostgreSQL service (defaults to Unix Domain Socket for zero port collision)
#PostgresService: #BaseService & {
	service_type: "postgres"
	protocol:     *"sql" | "tcp"
	mode:         *#ServiceTransport.Socket | #ServiceTransport.Loopback
	port:         *5432 | int
	database?:    string
	databases?:   [...string]
	user?:        string
	extensions?:  [...string]
}

// Strongly typed Kafka event bus (requires TCP loopback)
#KafkaService: #BaseService & {
	service_type: "kafka"
	protocol:     *"kafka" | "tcp"
	mode:         #ServiceTransport.Loopback
	port:         *9092 | int
	topics?:      [...string]
}

// Strongly typed Redis cache / queue (defaults to Unix Domain Socket for zero port collision)
#RedisService: #BaseService & {
	service_type: "redis"
	protocol:     *"redis" | "tcp"
	mode:         *#ServiceTransport.Socket | #ServiceTransport.Loopback
	port:         *6379 | int
	db?:          int & >=0 & <=15 | *0
}

// Strongly typed ClickHouse column store (HTTP/TCP loopback)
#ClickHouseService: #BaseService & {
	service_type: "clickhouse"
	protocol:     *"http" | "sql"
	mode:         #ServiceTransport.Loopback
	port:         *8123 | int
	tcp_port:     *9000 | int
}

// Strongly typed Temporal workflow orchestration service (gRPC/TCP loopback)
#TemporalService: #BaseService & {
	service_type: "temporal"
	protocol:     *"grpc" | "tcp"
	mode:         #ServiceTransport.Loopback
	port:         *7233 | int
	namespace?:   string | *"default"
}

// Strongly typed S3-compatible Object Storage (SeaweedFS loopback)
#ObjectStorageService: #BaseService & {
	service_type: "seaweedfs"
	protocol:     *"s3" | "http"
	mode:         #ServiceTransport.Loopback
	port:         *19000 | int
	buckets?:     [...string]
}

// Fallback custom service
#CustomService: #BaseService & {
	service_type: *"custom" | string
	protocol?:    string
}

// Union of all supported service blueprints
#ServiceSpec: #PostgresService | #KafkaService | #RedisService | #ClickHouseService | #TemporalService | #ObjectStorageService | #CustomService

// Cache specification for inputs, dependencies, and outputs.
#CacheSpec: {
	paths:        [...string]
	key_hash:     string // expression or glob used for hashing
	restore_keys?: [...string]
	backend:      *"local" | "s3-r2" | "gha"
}

// Secret specification declaring mandatory secrets.
#SecretSpec: {
	name:        string
	description?: string
	required:    *true | bool
	env_var?:    string
}
