package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// Pinned Rust 1.91.1 release archives (dtolnay/rust-toolchain 1.91.1) with Linux auto-patchelf.
_rust: schema.#ArchiveBuildSpec & {
	pname:   "rust"
	version: "1.91.1"
	src: {
		"aarch64-darwin": "https://static.rust-lang.org/dist/rust-1.91.1-aarch64-apple-darwin.tar.xz"
		"aarch64-linux":  "https://static.rust-lang.org/dist/rust-1.91.1-aarch64-unknown-linux-gnu.tar.xz"
		"x86_64-linux":   "https://static.rust-lang.org/dist/rust-1.91.1-x86_64-unknown-linux-gnu.tar.xz"
	}
	sha256: {
		"aarch64-darwin": "5c8c9ed5bc7ad5e3910e8599fa7c51aa78709f78397ba9110614036b6f5bc193"
		"aarch64-linux":  "be340c296bd18ad50a8af4f6c22fc744018f269f94474bdaf705da946803d64a"
		"x86_64-linux":   "db178028da493a663b2e344a142076fb0f72adea4120043983f488de9cf95214"
	}
	buildInputs: [
		{pname: "findutils"},
		{pname: "gnugrep"},
		{pname: "gnused"},
		{pname: "gawk"},
		{pname: "coreutils"},
		{pname: "auto-patchelf", platforms: ["linux"]},
		{pname: "patchelf", platforms: ["linux"]},
		{pname: "glibc", platforms: ["linux"]},
		{pname: "gcc-unwrapped", attr: "gcc-unwrapped.lib", platforms: ["linux"]},
		{pname: "zlib", platforms: ["linux"]},
	]
	installPhase: """
		set -eu
		installer=$(find "$src" -maxdepth 2 -name install.sh | head -n 1)
		dir=${installer%/install.sh}
		components=$(grep -E '^(rustc|cargo|rust-std-.*|clippy-preview|rustfmt-preview)$' "$dir/components" | paste -sd, -)
		bash "$installer" --prefix="$out" --components="$components" --disable-ldconfig --without=rust-docs
		rm -rf "$out/share/doc" "$out/lib/rustlib/uninstall.sh" "$out/lib/rustlib/install.log"
		# rustc strips Mach-O outputs (`strip = "debuginfo"`, cargo's default without debuginfo:
		# release, CARGO_PROFILE_DEV_DEBUG=0) with `rust-objcopy <flag> <file>`. This one (LLVM 21)
		# leaves the string table 4-byte aligned after an odd indirect symbol table, and macOS 27's
		# dyld refuses to dlopen such a proc-macro ("mis-aligned LINKEDIT string pool"); Rust 1.98's
		# LLVM fixed it. Apple's strip keeps the alignment: rustc's strips go to it.
		if [ "$(uname -s)" = Darwin ]; then
			tools=$(dirname "$(find "$out/lib/rustlib" -path '*/bin/rust-objcopy' | head -n 1)")
			mv "$tools/rust-objcopy" "$tools/rust-objcopy-llvm"
			cat > "$tools/rust-objcopy" <<'EOF'
		#!/bin/sh
		# rustc's Mach-O strips go to Apple's strip (posthog overlay enve.cue), the rest to LLVM's.
		if [ "$#" -eq 2 ] && [ -f "$2" ]; then
			case "$1" in
			--strip-debug) exec /usr/bin/strip -S "$2" ;;
			--discard-all) exec /usr/bin/strip -x "$2" ;;
			--strip-all) exec /usr/bin/strip "$2" ;;
			esac
		fi
		exec "$(dirname "$0")/rust-objcopy-llvm" "$@"
		EOF
			chmod 0755 "$tools/rust-objcopy"
			"$tools/rust-objcopy" --version
		fi
		if [ "$(uname -s)" = Linux ]; then
			auto-patchelf --paths "$out" --libs $(printf '%s' "$LIBRARY_PATH" | tr ':' ' ')
			root=$(cd /nix/store && pwd -P)
			outreal=$(cd "$out" && pwd -P)
			shopt -s globstar
			for elf in "$out"/**; do
				[ -f "$elf" ] && [ ! -L "$elf" ] || continue
				interp=$(patchelf --print-interpreter "$elf" 2>/dev/null) || interp=
				case "$interp" in "$root"/*) patchelf --set-interpreter "/nix/store/${interp#"$root"/}" "$elf" ;; esac
				rpath=$(patchelf --print-rpath "$elf" 2>/dev/null) || continue
				fixed=
				for entry in ${rpath//:/ }; do
					case "$entry" in
					"$outreal"/lib | "$out"/lib)
						rel=$(realpath --relative-to="$(dirname "$elf")" "$out/lib")
						case "$rel" in .) entry='$ORIGIN' ;; *) entry='$ORIGIN'/$rel ;; esac
						;;
					"$root"/*) entry="/nix/store/${entry#"$root"/}" ;;
					esac
					case ":$fixed:" in *":$entry:"*) ;; *) fixed=${fixed:+$fixed:}$entry ;; esac
				done
				[ "$fixed" = "$rpath" ] || patchelf --set-rpath "$fixed" "$elf"
			done
		fi
		"$out/bin/rustc" --version
		"$out/bin/cargo" --version
		"$out/bin/cargo-clippy" --version
		"$out/bin/rustfmt" --version
		for bin in "$out"/lib/rustlib/*/bin; do
			"$bin/rust-objcopy" --version
			"$bin/rust-lld" -flavor gnu --version
		done
		"""
}

_seaweedfs_base: {
	// Seaweed imports AWS keys as an admin identity; cache credentials must stay outside the fixture.
	environment: {AWS_ACCESS_KEY_ID: "", AWS_SECRET_ACCESS_KEY: ""}
	command: "weed server -ip=127.0.0.1 -master.raftHashicorp -s3 -s3.port=$PORT -s3.port.grpc=$PORT_S3_GRPC -s3.port.iceberg=0 -s3.port.lance=0 -master.port=$PORT_MASTER -master.port.grpc=$PORT_MASTER_GRPC -volume.port=$PORT_VOLUME -volume.port.grpc=$PORT_VOLUME_GRPC -filer.port=$PORT_FILER -filer.port.grpc=$PORT_FILER_GRPC -dir=\"$DATA_DIR\" -volume.max=1000 -master.volumePreallocate=false"
}

// PostHog Polyglot Monorepo — Zero-Docker Developer Environment & Microservice Topology
profiles: dev: schema.#Profile & {
	name:        "posthog-platform-dev"
	description: "PostHog Polyglot Monorepo (Django + ClickHouse + Kafka + Temporal + SeaweedFS)"

	// Upstream's pins: python 3.14.7, node 24, pnpm 10, postgres 15, go 1.26, ClickHouse 26.6.2.158,
	// redis 8.10, ruff 0.16, git 2.48+.
	tools: [
		{pname: "python3", version: "3.14.7"},
		pkgs.uv,
		pkgs.postgresql_15,
		// Compose's ClickHouse 26.6.2.158 release binaries (26.8 changes JSON float/uint overflow).
		schema.#ArchiveBuildSpec & {
			pname:   "clickhouse"
			version: "26.6.2.158"
			src: {
				"aarch64-darwin": "https://github.com/ClickHouse/ClickHouse/releases/download/v26.6.2.158-stable/clickhouse-macos-aarch64"
				"aarch64-linux":  "https://github.com/ClickHouse/ClickHouse/releases/download/v26.6.2.158-stable/clickhouse-common-static-26.6.2.158-arm64.tgz"
				"x86_64-linux":   "https://github.com/ClickHouse/ClickHouse/releases/download/v26.6.2.158-stable/clickhouse-common-static-26.6.2.158-amd64.tgz"
			}
			sha256: {
				"aarch64-darwin": "0be693bf5d2f3a82c18e2047b96d09aed01188758da2c9223fb3e9a07462e7ac"
				"aarch64-linux":  "ed312f77219abd152afaaa8bdaacc2f03a4a0cbc9d7fb11f16f8245159efe150"
				"x86_64-linux":   "43340e96a000cc76b66ba7bca013b5fd567379c5a67d7ea9c95b3ab92ddbed2d"
			}
			buildInputs: [{pname: "findutils"}]
			installPhase: """
				set -eu
				mkdir -p "$out/bin"
				cp "$(find "$src" -type f \\( -path "$src/clickhouse" -o -path '*/usr/bin/clickhouse' \\) | head -n 1)" "$out/bin/clickhouse"
				chmod 0755 "$out/bin/clickhouse"
				"$out/bin/clickhouse" --version
				for tool in server client local; do ln -s clickhouse "$out/bin/clickhouse-$tool"; done
				"""
		},
		pkgs.redis,
		pkgs.nodejs & {version: "24"},
		pkgs.pnpm & {version: "10"},
		pkgs.go & {version: "1.26"},
		_rust,
		{pname: "golangci-lint"},
		{pname: "buf"},
		{pname: "actionlint"},
		{pname: "shellcheck"},
		{pname: "hadolint"},
		pkgs.ruff,
		pkgs.git,
		// libstdc++ for binary wheels (grpcio, numpy, pyarrow) and native Rust crate build deps.
		{pname: "gcc-unwrapped", attr: "gcc-unwrapped.lib"},
		{pname: "gcc", platforms: ["linux"]},
		{pname: "binutils", platforms: ["linux"]},
		{pname: "gnumake"},
		{pname: "perl"},
		{pname: "pkg-config"},
		{pname: "openssl", attr: "openssl.dev"},
		// Apple Silicon linker (`-fuse-ld=lld`) and libomp for xgboost's macOS wheel.
		{pname: "lld", attr: "llvmPackages_23.lld", version: "23.1.3", platforms: ["aarch64-darwin"]},
		{pname: "openmp", attr: "llvmPackages.openmp", libraries: true, platforms: ["aarch64-darwin"]},
		{pname: "cargo-nextest"},
		{pname: "jq"},
		pkgs.#PlaywrightBrowsers & {version: "1.60.0", features: ["chromium-headless-shell", "chromium", "webkit"]},
		// Pinned cargo-shear 1.1.12 (1.14 flags dev-target-only deps that upstream lint ignores).
		schema.#ArchiveBuildSpec & {
			pname:   "cargo-shear"
			version: "1.1.12"
			src: {
				"aarch64-darwin": "https://github.com/Boshen/cargo-shear/releases/download/v1.1.12/cargo-shear-aarch64-apple-darwin.tar.gz"
				"aarch64-linux":  "https://github.com/Boshen/cargo-shear/releases/download/v1.1.12/cargo-shear-aarch64-unknown-linux-musl.tar.gz"
				"x86_64-linux":   "https://github.com/Boshen/cargo-shear/releases/download/v1.1.12/cargo-shear-x86_64-unknown-linux-musl.tar.gz"
			}
			sha256: {
				"aarch64-darwin": "491e376ad485d49d3ca927900ada2a832af8d75079c29550905be56b72020301"
				"aarch64-linux":  "aba8fcb4e37d3d04c6d46dcb666698756711e03fd8037ffc400ced226fade50f"
				"x86_64-linux":   "5acdc881727cf1875288d0c0097229d5a23d9ccdd8fd77042538022caa1eda50"
			}
			installPhase: """
				set -eu
				mkdir -p "$out/bin"
				cp "$src/cargo-shear" "$out/bin/cargo-shear"
				chmod 0755 "$out/bin/cargo-shear"
				"$out/bin/cargo-shear" --version
				"""
		},
		{pname: "protobuf"},
		{pname: "sqlx-cli"},
		{pname: "util-linux"},
		{pname: "curl"},
		{pname: "brotli"},
		{pname: "azurite"},
		// amazon/dynamodb-local:3.3.1 on Zulu JDK 21 (dated v3.x archive with multi-platform sqlite4java).
		{pname: "jdk21_headless"},
		schema.#ArchiveBuildSpec & {
			pname:   "dynamodb-local"
			version: "3.3.1"
			src:     "https://d1ni2b6xgvw0s0.cloudfront.net/v3.x/dynamodb_local_2026-07-31.tar.gz"
			sha256:  "f80bcec477f85f57e2c77f8d54aa6b672a8403fceff0c450560aee1cf6c21163"
			installPhase: """
				set -eu
				mkdir -p "$out/share/dynamodb-local" "$out/bin"
				cp -R DynamoDBLocal.jar DynamoDBLocal_lib "$out/share/dynamodb-local/"
				cat > "$out/bin/dynamodb-local" <<'LAUNCHER'
				#!/bin/sh
				home="$(cd "$(dirname "$(readlink -f "$0")")/../share/dynamodb-local" && pwd)"
				exec java -Djava.library.path="$home/DynamoDBLocal_lib" -jar "$home/DynamoDBLocal.jar" "$@"
				LAUNCHER
				chmod 0755 "$out/bin/dynamodb-local"
				"""
		},
		{pname: "etcd"},
		{pname: "ripgrep"},
		{pname: "bash"},
		{pname: "coreutils"},
		{pname: "gnused"},
	]

	environment: {
		TZ:                                   "UTC"
		PGTZ:                                 "UTC"
		DATABASE_URL:                         "postgres://posthog:posthog@127.0.0.1:${ENVE_SERVICE_POSTGRES_PORT}/posthog"
		PGHOST:                               "127.0.0.1"
		PGPORT:                               "${ENVE_SERVICE_POSTGRES_PORT}"
		PGUSER:                               "posthog"
		PGPASSWORD:                           "posthog"
		PGDATABASE:                           "posthog"
		POSTHOG_DB_USER:                      "posthog"
		POSTHOG_DB_PASSWORD:                  "posthog"
		POSTHOG_POSTGRES_HOST:                "127.0.0.1"
		POSTHOG_POSTGRES_PORT:                "${ENVE_SERVICE_POSTGRES_PORT}"
		REDIS_URL:                            "redis://127.0.0.1:${ENVE_SERVICE_REDIS_PORT}"
		REDIS_PORT:                           "${ENVE_SERVICE_REDIS_PORT}"
		CLICKHOUSE_HOST:                      "127.0.0.1"
		CLICKHOUSE_HTTP_PORT:                 "${ENVE_SERVICE_CLICKHOUSE_PORT}"
		CLICKHOUSE_TCP_PORT:                  "${ENVE_SERVICE_CLICKHOUSE_PORT_NATIVE}"
		CLICKHOUSE_DATABASE:                  "test_posthog"
		CLICKHOUSE_TEST_CLUSTER_HOST:         "127.0.0.1"
		CLICKHOUSE_TEST_CLUSTER_DATABASE:     "posthog_test"
		CLICKHOUSE_LOGS_CLUSTER_HOST:         "127.0.0.1"
		CLICKHOUSE_LOGS_CLUSTER_PORT:         "${ENVE_SERVICE_CLICKHOUSE_PORT_NATIVE}"
		KAFKA_HOSTS:                          "127.0.0.1:${ENVE_SERVICE_KAFKA_PORT}"
		KAFKA_URL:                            "127.0.0.1:${ENVE_SERVICE_KAFKA_PORT}"
		TEMPORAL_HOST:                        "127.0.0.1"
		TEMPORAL_PORT:                        "${ENVE_SERVICE_TEMPORAL_PORT}"
		TEMPORAL_ADDRESS:                     "127.0.0.1:${ENVE_SERVICE_TEMPORAL_PORT}"
		OBJECT_STORAGE_ENABLED:               "True"
		// Presigned-URL tests match `^http://localhost:\d+/`; ClickHouse S3 staging uses 127.0.0.1.
		OBJECT_STORAGE_ENDPOINT:              "http://localhost:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		OBJECT_STORAGE_ACCESS_KEY_ID:         "object_storage_root_user"
		OBJECT_STORAGE_SECRET_ACCESS_KEY:     "object_storage_root_password"
		NOTEBOOKS_FRAME_STORE_S3_ENDPOINT:    "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		BATCH_EXPORT_OBJECT_STORAGE_ENDPOINT: "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		IDENTITY_MATCHING_S3_ENDPOINT:        "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		DICTIONARY_STAGING_S3_ENDPOINT:       "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		DATA_DELETION_STAGING_S3_ENDPOINT:    "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		DATAWAREHOUSE_BUCKET_DOMAIN:          "127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		CLICKHOUSE_POSTGRES_HOST:             "127.0.0.1"
		CLICKHOUSE_OBJECT_STORAGE_HOST:       "127.0.0.1"
		AWS_ENDPOINT_URL:                     "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		AZURITE_BLOB_PORT:                    "${ENVE_SERVICE_AZURITE_PORT}"
		SECRET_KEY:                           "6b01eee4f945ca25045b5aab440b953461faf08693a9abbf1166dc7c6b9772da"
		DJANGO_SECRET_KEY:                    "6b01eee4f945ca25045b5aab440b953461faf08693a9abbf1166dc7c6b9772da"
		DEBUG:                                "0"
		TEST:                                 "1"
		SKIP_SERVICE_VERSION_REQUIREMENTS:    "1"
		npm_config_manage_package_manager_versions: "false"
		TURBO_ENV_MODE:                       "loose"
		COREPACK_ENABLE_DOWNLOAD_PROMPT:      "0"
		NO_PROXY:                             "127.0.0.1,localhost,::1"
	}

	services: {
		postgres: {
			database: "posthog"
			user:     "posthog"
			port:     5432
			command:  "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -p $PORT -c max_connections=1000 -c idle_in_transaction_session_timeout=300000 -c max_prepared_transactions=10"
			lifecycle: init: [
				"initdb -D \"$DATA_DIR\" -U postgres --auth-local=trust --auth-host=trust --locale=C.UTF-8 --encoding=UTF8",
			]
		}
		redis: {
			// DB allocation: 0 Rust, 1 Rust flags, 2 Rust ignored, 3 /flags integration, 16+n Python shard, 32+n AI-gateway.
			command: "rm -f \"$DATA_DIR/dump.rdb\" && exec redis-server --port $PORT --dir \"$DATA_DIR\" --daemonize no --databases 48 --save '' --appendonly no"
		}
		"valkey-cluster": {
			port: 6390
			ports: bus: 16390
			command: "rm -f \"$DATA_DIR/nodes.conf\" && exec redis-server --port $PORT --cluster-port $PORT_BUS --dir \"$DATA_DIR\" --daemonize no --save '' --appendonly no --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000"
			readinessProbe: command: "redis-cli -p $PORT ping"
			lifecycle: postStart:    "redis-cli -p $PORT cluster addslots $(seq 0 16383) >/dev/null && until redis-cli -p $PORT cluster info | rg -q '^cluster_state:ok'; do sleep 0.1; done"
		}
		clickhouse: {
			timeout: "90s"
			ports: {native: 9000, interserver: 9009, keeper: 9181, raft: 9234}
			files: "config.template.xml": source: "infra/clickhouse/config.xml"
			command: "infra/clickhouse/start.sh"
			lifecycle: {
				preStart: {run: "showcase/scripts/exclusive.sh clickhouse-host-udfs infra/clickhouse/build_host_udfs.sh", timeout: "10m"}
				postStart: "clickhouse-client --port $PORT_NATIVE -q 'SELECT 1; SYSTEM FLUSH LOGS;'"
			}
		}
		// Match Redpanda's 3s initial rebalance delay and admit ClickHouse's 3s Kafka consumer sessions.
		kafka: command: "cd \"$DATA_DIR\" && exec kafka-server-start.sh server.properties --override group.initial.rebalance.delay.ms=3000 --override group.min.session.timeout.ms=3000"
		temporal: {}
		seaweedfs: _seaweedfs_base & {
			port: 19000
			ports: {master: 19001, volume: 19002, filer: 8888, s3_grpc: 29000, master_grpc: 29001, volume_grpc: 29002, filer_grpc: 18888}
			lifecycle: postStart: {run: "bash showcase/scripts/seaweedfs_setup.sh", timeout: "90s"}
		}
		"seaweedfs-open": schema.#SeaweedfsService & _seaweedfs_base & {
			port: 8333
			ports: {master: 9333, volume: 18080, filer: 18889, s3_grpc: 28333, master_grpc: 19333, volume_grpc: 28080, filer_grpc: 28889}
		}
		etcd: {
			port: 2379
			ports: peer: 2380
			command: "etcd --name default --data-dir \"$DATA_DIR\" --listen-client-urls http://127.0.0.1:$PORT --advertise-client-urls http://127.0.0.1:$PORT --listen-peer-urls http://127.0.0.1:$PORT_PEER --initial-advertise-peer-urls http://127.0.0.1:$PORT_PEER --initial-cluster default=http://127.0.0.1:$PORT_PEER"
			readinessProbe: command: "etcdctl --endpoints=http://127.0.0.1:$PORT endpoint health"
		}
		dynamodb: {
			port:    18010
			command: "dynamodb-local -inMemory -sharedDb -disableTelemetry -port $PORT"
			readinessProbe: command: "curl -s -o /dev/null http://127.0.0.1:$PORT/"
			timeout: "60s"
		}
		maildev: {
			port: 1080
			ports: smtp: 1025
			command: "node infra/maildev/node_modules/maildev/bin/maildev --ip 127.0.0.1 --web $PORT --smtp $PORT_SMTP --mail-directory \"$DATA_DIR\" --silent"
			readinessProbe: path: "/healthz"
			lifecycle: preStart: {run: "showcase/scripts/exclusive.sh maildev-node-modules bash infra/maildev/install.sh", timeout: "5m"}
		}
		azurite: {
			command: "azurite-blob --blobHost 127.0.0.1 --blobPort $PORT --location \"$DATA_DIR\""
			port:    10000
			readinessProbe: path: "/"
			timeout: "30s"
		}
	}
}
