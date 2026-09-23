package replay

// PostHog showcase test services and environment, adapted for replay.
// Application servers whose sources are outside the replay archive stay in the reference overlay.
profiles: {
    dev: {
    "description": "PostHog Polyglot Monorepo (Django + Vite + Node Ingestion + Rust Services + Go AI Gateway + ClickHouse + Kafka + Temporal + SeaweedFS)",
    "disabledServices": [],
    "environment": {
        "CAPTURE_PORT": "3000",
        "CLICKHOUSE_DATABASE": "posthog",
        "CLICKHOUSE_HOST": "127.0.0.1",
        "CLICKHOUSE_HTTP_PORT": "8123",
        "CLICKHOUSE_HOGQL_USE_NEW_EVENTS_SCHEMA": "false",
        "CLICKHOUSE_POSTGRES_HOST": "127.0.0.2",
        "CLICKHOUSE_POSTGRES_PORT": "5432",
        "CLICKHOUSE_SECURE": "False",
        "CLICKHOUSE_TCP_PORT": "9000",
        "CLICKHOUSE_TEST_CLUSTER_DATABASE": "posthog_test",
        "CLICKHOUSE_TEST_CLUSTER_HOST": "127.0.0.1",
        "CLICKHOUSE_TEST_CLUSTER_PASSWORD": "autoresearchpass",
        "CLICKHOUSE_TEST_CLUSTER_SECURE": "False",
        "CLICKHOUSE_TEST_CLUSTER_USER": "autoresearch",
        "CLICKHOUSE_TEST_CLUSTER_VERIFY": "False",
        "CLICKHOUSE_VERIFY": "False",
        "DAGSTER_TEST_POSTGRES_URL": "postgresql://posthog:posthog@127.0.0.2:5432/test_dagster",
        "DATABASE_URL": "postgres://posthog:posthog@127.0.0.2:5432/posthog",
        "DEBUG": "0",
        "FLAGS_REDIS_URL": "redis://127.0.0.1:16379/1",
        "KAFKA_HOSTS": "127.0.0.1:19092",
        "KAFKA_URL": "127.0.0.1:19092",
        "NOTEBOOKS_FRAME_STORE_S3_ENDPOINT": "http://127.0.0.1:19000",
        "OBJECT_STORAGE_ACCESS_KEY_ID": "object_storage_root_user",
        "OBJECT_STORAGE_ENABLED": "True",
        "OBJECT_STORAGE_ENDPOINT": "http://127.0.0.1:19000",
        "OBJECT_STORAGE_SECRET_ACCESS_KEY": "object_storage_root_password",
        "OIDC_RSA_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCpwZgE4DqXavNG\ncBbtAN4DhkbQyoNDJP9sAtbm20uocD3bZuEBzysE8WEcuIs1zxhQeX1TTfKp1NWG\nC0u6EYPxLTIWSGhwoh416hjm4dT5DWwVbRhee4XZFyG7FBdDsp37Z5LMt+y97zWU\n0bgqY/sG4CgfJU+8FEQ2KI5viyCkVs7JC57Cc4twsa93Blaqg4WNkKgoCF6tcUxQ\nkeiWNHj1jffo41ySsoG/sVntDIUeZPqhXFDqtjb/kPJU61WXtGSCh624dU6kX+zh\nWL90ZrXN4sVGAi6HuR6fwUefd1rtDzssSWjoKoB2wMr2SVJ9w13BTU3ynpp0vDnT\n7S4KormXAgMBAAECggEAAr7i2pFV4UUVkjoV5Ndyv9PYKWBdJyTeDL0vBKTfYGYQ\nWhAb64+SPo445+IEPmaPGh4c7NAB8MVEftqH6waFf80fVkTti4TTwEN9C57zduPE\nr8QH9N9ClvRM013L0oh9DafrM+x1o8zOrQ2HUQg08zOE8pwD4iLhx454X018xaur\nAl8za9atR2hasRc8PsqQgUmV7SjfLgszDEPXuG7VBVxxtd2nlP9g8NTO57mZCFUP\nUKiDk/Zs61qLLrtLvjQC/+rxt+RVRNJLs2ipUINp077/r6TYwiNdSvd2ClAHBUig\nWL9fKFAJ7pjqr5F0OkKhlLmbRDAaUDs3Pl3mFX4CIQKBgQDe0sbR8Iw6f8a6c1or\nFjDNfCSTSO79mEECEMo4jhRSGQ5QgxoHZiwdtx77yoJut8LmSdB8Iy2bAcTK+1+z\nbEbXYwfN9bf+cgSh49jOR86IDSazPavBFA+A29o2n9wUw8feXXUjGEZXu50Nk2t6\nS/SR8ogY9oKYNYEhqt5aJL5vmwKBgQDDCBb2l29B8nSX7Pz+pvcdiawHpmSl7vBE\nlQ8tjNKEhTOPp6FgIDesb4Pw2Ah0m0KG4rJqZnItbvQdYaQnHu2+aHLrol1lK7MT\ng7EJCpt6RdkwTrrMXmFNBWk9AgFaIaK+C8Hw4IIMFEsJlghmRWd36vtOomuV+Fc8\nfNPKYn0DtQKBgQDNLlIeZ974z0hz0FyraFewICyd438OzfCusj9ELLDRmHjx8oc5\nYQAmrMU/Ho9U3Kn/3OC6LrqEDfDk6OyLD518IJjDMw0mpF9Xo7O037Jy3YlRa+yI\ncqyD/+7Edhf2lwGo5W5DzsqXZw+LvMAvcVnYOvjP488F0d8C3ZC6eTNTGQKBgF+B\nbaVR4QS9U0U2o2mcn7SSP3D7lZwAVx5ulCEtLcYBaI93ejoVbM3/SfA+Cl33zes5\nxj7+bfk7tUVSFE2oAqpUgbpMJ0oszSPIQIB59ks5OzNByo3bxfAurytV+Q2HHSfN\noCpx9p0trtVB6FkUsadypaALP34QP7/6LMiV1DxlAoGAViUvKdIsEJ247qkgDwGv\nL1nzjkqrxPCmPg2aoAnG/S0PkIgTOf3PCIDd4Kwe96AtA+CUKHAfHAZU4Pi4Dk4b\nmVnsc4t649WGh49uh37R9KxGmbQKd7fKbfUfNsHe7sSjm2I0ng9KymFc8mGvtRRN\nQ3xJzaxHgiwXenLUMBhwu/w=\n-----END PRIVATE KEY-----",
        "PERSONS_DATABASE_URL": "postgres://posthog:posthog@127.0.0.2:5432/test_posthog_persons",
        "PERSONS_DB_WRITER_URL": "postgres://posthog:posthog@127.0.0.2:5432/test_posthog_persons",
        "PERSONS_DB_READER_URL": "postgres://posthog:posthog@127.0.0.2:5432/test_posthog_persons",
        "PERSON_ON_EVENTS_V2_ENABLED": "true",
        "PGHOST": "127.0.0.2",
        "PGPASSWORD": "posthog",
        "PGPORT": "5432",
        "PGUSER": "posthog",
        "POSTHOG_DB_PASSWORD": "posthog",
        "POSTHOG_DB_USER": "posthog",
        "POSTHOG_POSTGRES_HOST": "127.0.0.2",
        "POSTHOG_POSTGRES_PORT": "5432",
        "REDIS_PORT": "16379",
        "REDIS_URL": "redis://127.0.0.1:16379",
        "SANDBOX_JWT_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCpwZgE4DqXavNG\ncBbtAN4DhkbQyoNDJP9sAtbm20uocD3bZuEBzysE8WEcuIs1zxhQeX1TTfKp1NWG\nC0u6EYPxLTIWSGhwoh416hjm4dT5DWwVbRhee4XZFyG7FBdDsp37Z5LMt+y97zWU\n0bgqY/sG4CgfJU+8FEQ2KI5viyCkVs7JC57Cc4twsa93Blaqg4WNkKgoCF6tcUxQ\nkeiWNHj1jffo41ySsoG/sVntDIUeZPqhXFDqtjb/kPJU61WXtGSCh624dU6kX+zh\nWL90ZrXN4sVGAi6HuR6fwUefd1rtDzssSWjoKoB2wMr2SVJ9w13BTU3ynpp0vDnT\n7S4KormXAgMBAAECggEAAr7i2pFV4UUVkjoV5Ndyv9PYKWBdJyTeDL0vBKTfYGYQ\nWhAb64+SPo445+IEPmaPGh4c7NAB8MVEftqH6waFf80fVkTti4TTwEN9C57zduPE\nr8QH9N9ClvRM013L0oh9DafrM+x1o8zOrQ2HUQg08zOE8pwD4iLhx454X018xaur\nAl8za9atR2hasRc8PsqQgUmV7SjfLgszDEPXuG7VBVxxtd2nlP9g8NTO57mZCFUP\nUKiDk/Zs61qLLrtLvjQC/+rxt+RVRNJLs2ipUINp077/r6TYwiNdSvd2ClAHBUig\nWL9fKFAJ7pjqr5F0OkKhlLmbRDAaUDs3Pl3mFX4CIQKBgQDe0sbR8Iw6f8a6c1or\nFjDNfCSTSO79mEECEMo4jhRSGQ5QgxoHZiwdtx77yoJut8LmSdB8Iy2bAcTK+1+z\nbEbXYwfN9bf+cgSh49jOR86IDSazPavBFA+A29o2n9wUw8feXXUjGEZXu50Nk2t6\nS/SR8ogY9oKYNYEhqt5aJL5vmwKBgQDDCBb2l29B8nSX7Pz+pvcdiawHpmSl7vBE\nlQ8tjNKEhTOPp6FgIDesb4Pw2Ah0m0KG4rJqZnItbvQdYaQnHu2+aHLrol1lK7MT\ng7EJCpt6RdkwTrrMXmFNBWk9AgFaIaK+C8Hw4IIMFEsJlghmRWd36vtOomuV+Fc8\nfNPKYn0DtQKBgQDNLlIeZ974z0hz0FyraFewICyd438OzfCusj9ELLDRmHjx8oc5\nYQAmrMU/Ho9U3Kn/3OC6LrqEDfDk6OyLD518IJjDMw0mpF9Xo7O037Jy3YlRa+yI\ncqyD/+7Edhf2lwGo5W5DzsqXZw+LvMAvcVnYOvjP488F0d8C3ZC6eTNTGQKBgF+B\nbaVR4QS9U0U2o2mcn7SSP3D7lZwAVx5ulCEtLcYBaI93ejoVbM3/SfA+Cl33zes5\nxj7+bfk7tUVSFE2oAqpUgbpMJ0oszSPIQIB59ks5OzNByo3bxfAurytV+Q2HHSfN\noCpx9p0trtVB6FkUsadypaALP34QP7/6LMiV1DxlAoGAViUvKdIsEJ247qkgDwGv\nL1nzjkqrxPCmPg2aoAnG/S0PkIgTOf3PCIDd4Kwe96AtA+CUKHAfHAZU4Pi4Dk4b\nmVnsc4t649WGh49uh37R9KxGmbQKd7fKbfUfNsHe7sSjm2I0ng9KymFc8mGvtRRN\nQ3xJzaxHgiwXenLUMBhwu/w=\n-----END PRIVATE KEY-----",
        "SECRET_KEY": "6b01eee4f945ca25045b5aab440b953461faf08693a9abbf1166dc7c6b9772da",
        "TEMPORAL_ADDRESS": "127.0.0.1:7233",
        "TEMPORAL_HOST": "127.0.0.1",
        "TEMPORAL_PORT": "7233",
        "TEST": "1",
        "PYTHONNOUSERSITE": "1",
        "BASH_ENV": "/dev/null",
        "ENV": "/dev/null",
        "UV_PYTHON_DOWNLOADS": "never",
        "UV_PYTHON_PREFERENCE": "only-system",
        "OPENSSL_NO_VENDOR": "1",
        "SQLX_OFFLINE": "true",
        "E2E_TESTING": "1",
        "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS": "true",
        "PLAYWRIGHT_BROWSERS_PATH": "/home/tonky/.cache/ms-playwright",
        "BASE_URL": "http://127.0.0.1:8000",
        "NO_PROXY": "127.0.0.1,localhost,::1",
        "no_proxy": "127.0.0.1,localhost,::1"
    },
    "gitHooks": {
        "clippy": false,
        "cue_fmt": false,
        "custom": {},
        "golangci_lint": false,
        "prettier": false,
        "ruff": false
    },
    "hosts": {
        "clickhouse": "127.0.0.1",
        "clickhouse-coordinator": "127.0.0.1",
        "db": "127.0.0.2",
        "kafka": "127.0.0.1",
        "objectstorage": "127.0.0.1",
        "redis7": "127.0.0.1",
        "seaweedfs": "127.0.0.1",
        "temporal": "127.0.0.1",
        "web": "127.0.0.1"
    },
    "name": "posthog-replay",
    "ports": [],
    "services": {
        "postgres": {
            "command": "postgres -D .enve/data/postgres -k /tmp -h 127.0.0.2 -p 5432 -c fsync=off -c synchronous_commit=off",
            "dataDir": ".enve/data/postgres",
            "database": "posthog",
            "dependsOn": [],
            "directory": ".",
            "enabled": true,
            "environment": {
                "DATABASE_URL": "postgresql://postgres@localhost:5432/postgres",
                "PGDATA": ".enve/data/postgres",
                "PGHOST": "/tmp",
                "PGPORT": "5432",
                "PGUSER": "postgres"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "command": "pg_isready -h 127.0.0.2 -p 5432 -U posthog",
                "originDir": "/home/tonky/projects/posthog",
                "port": 5432,
                "retries": 3,
                "timeout": "15000ms",
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "lifecycle": {
                "init": [
                    "test -d .enve/data/postgres/base || initdb -D .enve/data/postgres -U posthog --auth-local=trust --auth-host=trust --no-sync"
                ],
                "postStart": [
                    "psql -h 127.0.0.2 -p 5432 -U posthog -d postgres -c 'CREATE ROLE postgres SUPERUSER LOGIN;' || true",
                    "psql -h 127.0.0.2 -p 5432 -U posthog -d postgres -c 'CREATE DATABASE posthog;' || true",
                    "psql -h 127.0.0.2 -p 5432 -U posthog -d postgres -c 'CREATE DATABASE test_posthog;' || true",
                    "psql -h 127.0.0.2 -p 5432 -U posthog -d postgres -c 'CREATE DATABASE test_posthog_persons;' || true",
                    "psql -h 127.0.0.2 -p 5432 -U posthog -d postgres -c 'CREATE DATABASE test_dagster;' || true",
                    "sh -c 'if [ -f showcase/snapshots/test_posthog.sql.gz ]; then count=$(psql -h 127.0.0.2 -p 5432 -U posthog -d test_posthog -tAc \"SELECT count(*) FROM django_migrations\" 2>/dev/null || echo 0); if [ \"$count\" -lt 2000 ]; then gunzip -c showcase/snapshots/test_posthog.sql.gz | psql -h 127.0.0.2 -p 5432 -U posthog -q -d test_posthog || true; fi; fi'",
                    "sh -c 'SNAPSHOT=\"${HOME}/.cache/enact/snapshots/posthog_template_pg15.dump\"; if [ -s \"$SNAPSHOT\" ]; then for db in posthog test_posthog; do psql -h 127.0.0.2 -p 5432 -U posthog -d \"$db\" -c \"SELECT 1 FROM posthog_user LIMIT 1;\" >/dev/null 2>&1 || pg_restore -h 127.0.0.2 -p 5432 -U posthog -d \"$db\" --no-owner --no-acl --clean --if-exists \"$SNAPSHOT\" 2>/dev/null || true; done; fi'",
                    "sh -c 'PERSONS_SNAPSHOT=\"${HOME}/.cache/enact/snapshots/posthog_persons_template_pg15.dump\"; if [ -s \"$PERSONS_SNAPSHOT\" ]; then for db in test_posthog_persons posthog_persons; do psql -h 127.0.0.2 -p 5432 -U posthog -d postgres -c \"CREATE DATABASE $db;\" 2>/dev/null || true; psql -h 127.0.0.2 -p 5432 -U posthog -d \"$db\" -c \"SELECT 1 FROM posthog_person LIMIT 1;\" >/dev/null 2>&1 || pg_restore -h 127.0.0.2 -p 5432 -U posthog -d \"$db\" --no-owner --no-acl --clean --if-exists \"$PERSONS_SNAPSHOT\" 2>/dev/null || true; done; fi'"
                ]
            },
            "name": "postgres",
            "package": {
                "pname": "postgresql",
                "version": "15"
            },
            "packages": [],
            "port": 5432,
            "readinessProbe": {
                "command": "psql -h 127.0.0.2 -p 5432 -U posthog -d postgres -c 'SELECT 1;'",
                "originDir": "/home/tonky/projects/posthog",
                "port": 5432,
                "timeout": "15000ms",
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "socketDir": "/tmp",
            "timeout": "15000ms",
            "user": "posthog",
            "volumes": [],
            "watch": []
        },
        "redis": {
            "command": "redis-server --port 16379 --dir .enve/data/redis --save '' --appendonly no --daemonize no",
            "dataDir": ".enve/data/redis",
            "dependsOn": [],
            "directory": ".",
            "enabled": true,
            "environment": {
                "REDIS_PORT": "6379",
                "REDIS_URL": "redis://localhost:6379/0"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "originDir": "/home/tonky/projects/posthog",
                "port": 16379,
                "retries": 3,
                "timeout": "800ms",
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "lifecycle": {
                "init": [
                    "mkdir -p .enve/data/redis"
                ]
            },
            "name": "redis",
            "package": "redis",
            "packages": [],
            "port": 16379,
            "readinessProbe": {
                "command": "redis-cli -p 16379 ping",
                "originDir": "/home/tonky/projects/posthog",
                "port": 16379,
                "timeout": "1500ms",
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "timeout": "1500ms",
            "volumes": [],
            "watch": []
        },
        "clickhouse": {
            "command": "sh -c 'mkdir -p showcase/config/udf .enve/config && test -f docker/clickhouse/user_defined_function.xml && cp -f docker/clickhouse/user_defined_function.xml showcase/config/udf/ || true; test -f posthog/user_scripts/latest_user_defined_function.xml && cp -f posthog/user_scripts/latest_user_defined_function.xml showcase/config/udf/ || true; printf \"127.0.0.1 localhost\\n127.0.0.2 db\\n\" > .enve/config/hosts && exec bwrap --dev-bind / / --ro-bind .enve/config/hosts /etc/hosts --die-with-parent -- clickhouse-server --config-file showcase/config/clickhouse.xml'",
            "configFile": ".enve/config/clickhouse/config.xml",
            "dataDir": ".enve/data/clickhouse",
            "dependsOn": [
                {
                    "service": "kafka",
                    "condition": "ready"
                }
            ],
            "directory": ".",
            "enabled": true,
            "environment": {
                "CLICKHOUSE_ACCESS_DIR": ".enve/data/clickhouse/access/",
                "CLICKHOUSE_DATA_DIR": ".enve/data/clickhouse",
                "CLICKHOUSE_FORMAT_SCHEMA_DIR": ".enve/data/clickhouse/format_schemas/",
                "CLICKHOUSE_HTTP_PORT": "8123",
                "CLICKHOUSE_KEEPER_LOG_DIR": ".enve/data/clickhouse/keeper/log/",
                "CLICKHOUSE_KEEPER_SNAPSHOT_DIR": ".enve/data/clickhouse/keeper/snapshots/",
                "CLICKHOUSE_TCP_PORT": "9000",
                "CLICKHOUSE_TMP_DIR": ".enve/data/clickhouse/tmp/",
                "CLICKHOUSE_UDF_CONFIG": "udf/*_function.xml",
                "CLICKHOUSE_USER_FILES_DIR": ".enve/data/clickhouse/user_files/",
                "CLICKHOUSE_USER_SCRIPTS_DIR": "posthog/user_scripts/",
                "KAFKA_HOSTS": "127.0.0.1:19092"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "originDir": "/home/tonky/projects/posthog",
                "path": "http://127.0.0.1:8123/ping",
                "port": 8123,
                "retries": 3,
                "timeout": "15000ms",
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "lifecycle": {
                "postStart": [
                    "clickhouse-client -q 'CREATE DATABASE IF NOT EXISTS posthog;'",
                    "clickhouse-client -q 'CREATE DATABASE IF NOT EXISTS posthog_test;'",
                    "clickhouse-client -q 'SYSTEM FLUSH LOGS'",
                    "clickhouse-client -q 'CREATE ROW POLICY OR REPLACE autoresearch_own_queries_only ON system.query_log AS RESTRICTIVE FOR SELECT USING initial_user = currentUser() TO autoresearch'"
                ],
                "init": [
                    "mkdir -p .enve/data/clickhouse/tmp .enve/data/clickhouse/user_files .enve/data/clickhouse/format_schemas .enve/data/clickhouse/access .enve/data/clickhouse/keeper/log .enve/data/clickhouse/keeper/snapshots .enve/data/clickhouse/.enve/data/clickhouse && ln -sfn $(git rev-parse --show-toplevel)/posthog/user_scripts .enve/data/clickhouse/user_scripts && ln -sfn $(git rev-parse --show-toplevel)/posthog/user_scripts .enve/data/clickhouse/.enve/data/clickhouse/user_scripts && chmod -R +x posthog/user_scripts/ 2>/dev/null || true"
                ]
            },
            "name": "clickhouse",
            "package": "clickhouse",
            "packages": [],
            "port": 8123,
            "readinessProbe": {
                "command": "curl -s -f 'http://127.0.0.1:8123/?query=SELECT+1'",
                "originDir": "/home/tonky/projects/posthog",
                "port": 8123,
                "timeout": "15000ms",
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "tcpPort": 9000,
            "timeout": "15000ms",
            "volumes": [],
            "watch": []
        },
        "kafka": {
            "command": "tansu --listener-url tcp://127.0.0.1:19092 --advertised-listener-url tcp://127.0.0.1:19092 --storage-engine memory://tansu/",
            "dependsOn": [],
            "directory": ".",
            "enabled": true,
            "environment": {
                "KAFKA_BROKERS": "127.0.0.1:9092",
                "KAFKA_PORT": "9092",
                "RUST_LOG": "warn"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "originDir": "/home/tonky/projects/posthog",
                "port": 19092,
                "retries": 3,
                "timeout": "800ms",
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "lifecycle": {
                "postStart": [
                    ".venv/bin/python showcase/scripts/create_test_kafka_topics.py || true"
                ]
            },
            "name": "kafka",
            "package": "tansu",
            "packages": [],
            "port": 19092,
            "readinessProbe": {
                "originDir": "/home/tonky/projects/posthog",
                "port": 19092,
                "timeout": "1000ms",
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "storageEngine": "memory://tansu/",
            "timeout": "1500ms",
            "volumes": [],
            "watch": []
        },
        "seaweedfs": {
            "command": "weed mini -ip=127.0.0.1 -ip.bind=127.0.0.1 -dir=.enve/data/seaweedfs -s3.port=19000 -bucket=posthog,test-posthog,posthog-recordings,test-recordings,ai-blobs",
            "dataDir": ".enve/data/seaweedfs",
            "dependsOn": [],
            "directory": ".",
            "enabled": true,
            "environment": {
                "AWS_ACCESS_KEY_ID": "object_storage_root_user",
                "AWS_SECRET_ACCESS_KEY": "object_storage_root_password",
                "S3_BUCKET": "posthog,test-posthog,posthog-recordings,test-recordings,ai-blobs",
                "S3_ENDPOINT": "http://127.0.0.1:19000",
                "S3_PORT": "19000"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "originDir": "/home/tonky/projects/posthog",
                "port": 19000,
                "retries": 15,
                "timeout": "15000ms",
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "lifecycle": {
                "init": [
                    "mkdir -p .enve/data/seaweedfs"
                ]
            },
            "name": "seaweedfs",
            "package": "seaweedfs",
            "packages": [],
            "port": 19000,
            "readinessProbe": {
                "command": "curl -s -o /dev/null http://127.0.0.1:19000/",
                "originDir": "/home/tonky/projects/posthog",
                "port": 19000,
                "timeout": "6000ms",
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "timeout": "6000ms",
            "volumes": [],
            "watch": []
        },
        "temporal": {
            "command": "temporal server start-dev --port 7233 --headless --db-filename .enve/data/temporal/temporal.db",
            "dataDir": ".enve/data/temporal",
            "dbFilename": ".enve/data/temporal/temporal.db",
            "dependsOn": [],
            "directory": ".",
            "enabled": true,
            "environment": {
                "TEMPORAL_HOST": "127.0.0.1",
                "TEMPORAL_PORT": "7233"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "originDir": "/home/tonky/projects/posthog",
                "port": 7233,
                "retries": 3,
                "timeout": "5000ms",
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "lifecycle": {
                "init": [
                    "mkdir -p .enve/data/temporal"
                ]
            },
            "name": "temporal",
            "package": "temporal-cli",
            "packages": [],
            "port": 7233,
            "readinessProbe": {
                "command": "temporal operator cluster health --address 127.0.0.1:7233",
                "originDir": "/home/tonky/projects/posthog",
                "port": 7233,
                "timeout": "10000ms",
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "timeout": "10000ms",
            "volumes": [],
            "watch": []
        },
        "temporal-worker": {
            "command": "uv run --no-sync python3 manage.py start_temporal_worker --temporal-host 127.0.0.1 --temporal-port 7233 --task-queue analytics-platform-task-queue --metrics-port 7234",
            "dependsOn": [
                {
                    "service": "temporal",
                    "condition": "ready"
                },
                {
                    "service": "postgres",
                    "condition": "ready"
                },
                {
                    "service": "redis",
                    "condition": "ready"
                },
                {
                    "service": "clickhouse",
                    "condition": "ready"
                },
                {
                    "service": "seaweedfs",
                    "condition": "ready"
                }
            ],
            "directory": ".",
            "enabled": true,
            "environment": {
                "REDIS_URL": "redis://127.0.0.1:16379",
                "CELERY_BROKER_URL": "redis://127.0.0.1:16379",
                "CELERY_RESULT_BACKEND": "redis://127.0.0.1:16379",
                "TEST": "0",
                "E2E_TESTING": "1",
                "DISABLE_SECURE_SSL_REDIRECT": "1",
                "SECURE_COOKIES": "0",
                "SITE_URL": "http://127.0.0.1:8000",
                "INTERNAL_API_SECRET": "posthog123",
                "CLICKHOUSE_DATABASE": "posthog_test",
                "TEMPORAL_HOST": "127.0.0.1",
                "TEMPORAL_PORT": "7233",
                "TEMPORAL_NAMESPACE": "default"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "port": 7234,
                "retries": 25,
                "timeout": "25000ms",
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "name": "temporal-worker",
            "packages": [],
            "port": 7234,
            "readinessProbe": {
                "command": "curl -s -f http://127.0.0.1:7234/metrics",
                "port": 7234,
                "timeout": "25000ms",
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "timeout": "25000ms",
            "volumes": [],
            "watch": []
        },
        "server": {
            "command": "uv run --no-sync granian --interface asgi posthog.asgi:application --host 127.0.0.1 --port 8000 --workers 2",
            "dependsOn": [
                {
                    "service": "postgres",
                    "condition": "ready"
                },
                {
                    "service": "redis",
                    "condition": "ready"
                },
                {
                    "service": "clickhouse",
                    "condition": "ready"
                },
                {
                    "service": "seaweedfs",
                    "condition": "ready"
                },
                {
                    "service": "temporal",
                    "condition": "ready"
                }
            ],
            "directory": ".",
            "enabled": true,
            "environment": {
                "PORT": "8000",
                "REDIS_URL": "redis://127.0.0.1:16379",
                "CELERY_BROKER_URL": "redis://127.0.0.1:16379",
                "CELERY_RESULT_BACKEND": "redis://127.0.0.1:16379",
                "TEST": "0",
                "E2E_TESTING": "1",
                "DISABLE_SECURE_SSL_REDIRECT": "1",
                "SECURE_COOKIES": "0",
                "SITE_URL": "http://127.0.0.1:8000",
                "INTERNAL_API_SECRET": "posthog123",
                "CLICKHOUSE_DATABASE": "posthog_test",
                "TEMPORAL_HOST": "127.0.0.1",
                "TEMPORAL_PORT": "7233",
                "TEMPORAL_NAMESPACE": "default"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "port": 8000,
                "retries": 15,
                "timeout": "15000ms",
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "lifecycle": {
                "init": [
                    "mkdir -p frontend/dist share staticfiles",
                    "test -f frontend/dist/index.html || echo '<!DOCTYPE html><html><body><div id=\"root\">PostHog App</div></body></html>' > frontend/dist/index.html",
                    "touch frontend/dist/layout.html frontend/dist/exporter.html"
                ]
            },
            "name": "server",
            "packages": [],
            "port": 8000,
            "readinessProbe": {
                "command": "curl -s -f http://127.0.0.1:8000/_health",
                "port": 8000,
                "timeout": "15000ms",
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "timeout": "15000ms",
            "volumes": [],
            "watch": []
        }
    },
    "shellHook": "echo \"PostHog replay: just --list; just setup frontend; just test\"",
    "tools": [
        {
            "pname": "postgresql",
            "version": "15"
        },
        "redis",
        "clickhouse",
        "temporal-cli",
        "seaweedfs",
        "ripgrep",
        "jq",
        "watchexec",
        {
            "pname": "python3",
            "version": "3.13.13"
        },
        {
            "pname": "uv",
            "version": "0.12.17"
        },
        {
            "pname": "nodejs",
            "version": "24.20.0"
        },
        "pnpm",
        {
            "pname": "just",
            "version": "1.58.0"
        },
        "oxlint",
        "protobuf",
        "actionlint",
        "shellcheck"
    ]
}
}
