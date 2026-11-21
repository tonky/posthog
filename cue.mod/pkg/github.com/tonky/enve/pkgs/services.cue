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
temporal: {pname: "temporal"}
temporal_server: {pname: "temporal"}
temporal_cli: {pname: "temporal-cli"}
seaweedfs: {pname: "seaweedfs"}
nisshi: {pname: "nisshi"}
tansu: {pname: "nisshi"}
kafka: {pname: "apacheKafka"}
apacheKafka: {pname: "apacheKafka"}

// -------------------------------------------------------------
// High-Level Microservice & Daemon Presets (#Service presets)
// -------------------------------------------------------------

// The service presets are the schema's (`schema.#PostgresService` is
// `pkgs.#PostgresService`): one definition, so the two spellings cannot drift apart.
#PostgresService:   schema.#PostgresService
#RedisService:      schema.#RedisService
#ValkeyService:     schema.#ValkeyService
#GarageService:     schema.#GarageService
#NginxService:      schema.#NginxService
#MySQLService:      schema.#MySQLService
#MariaDBService:    schema.#MariaDBService
#ClickHouseService: schema.#ClickHouseService
#TemporalService:   schema.#TemporalService
#SeaweedfsService:  schema.#SeaweedfsService
#NisshiService:     schema.#NisshiService
#KafkaService:      schema.#KafkaService
#TansuService:      schema.#TansuService
