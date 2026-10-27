package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// The toolchain upstream's Rust jobs pin (dtolnay/rust-toolchain 1.91.1), from the release
// archives: no nixpkgs snapshot has it beside the pins below, and a newer clippy fails
// upstream's `-D warnings` lint on lints 1.91 doesn't have (~110 errors at the pin). On Linux
// its binaries expect a distribution's glibc: auto-patchelf points their interpreter and RPATH
// at the snapshot's, and RPATHs into the output become $ORIGIN-relative again, relative to
// each binary's own directory (lib/rustlib/<target>/bin/rust-lld's is ../../..).
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
	// install.sh's own tools, besides.
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

// PostHog Polyglot Monorepo
// Modern Zero-Docker Developer Environment & Microservice Topology
profiles: dev: schema.#Profile & {
	name:        "posthog-platform-dev"
	description: "PostHog Polyglot Monorepo (Django + ClickHouse + Kafka + Temporal + SeaweedFS)"

	// Upstream's pins, as close as one nixpkgs snapshot has them: python `==3.14.7`
	// (pyproject.toml), node `>=24 <25` (package.json engines), pnpm 10 (packageManager
	// pnpm@10.29.3: 10.34), postgres 15 (docker-compose: 15.12), go 1.26 (livestream go.mod:
	// 1.26.4), ClickHouse 26.6.2.158 (compose's, below). redis 8.10 runs newer than compose's
	// 7.2; ruff 0.16 than pyproject's ~=0.15.20 (lint runs the project's own, `uv run ruff`). git: the
	// agent's tests need a fetch that records the remote's HEAD (2.48+), newer than hosts'.
	tools: [
		{pname: "python3", version: "3.14.7"},
		pkgs.uv,
		pkgs.postgresql_15,
		// compose's ClickHouse, from its release binaries: no nixpkgs snapshot has 26.6 beside
		// the pins above (one snapshot serves every tool), and 26.8 parses JSON numbers
		// past Float64/UInt64 that cohort-seeder's ch tests expect it to reject.
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
			// The macOS binary decompresses itself on its first run: --version does it here, not in
			// the store. clickhouse-<tool> links to it, as the release packages install it.
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
		// Rust 1.91.1 (rustc, cargo, clippy, rustfmt), as every ci-rust*.yml job installs it.
		_rust,
		// The linters the jobs run (livestream, clickhouse_udfs, proto, workflows, terraform,
		// shellcheck.yml's scripts, container-images-ci.yml's Dockerfiles).
		{pname: "golangci-lint"},
		{pname: "buf"},
		{pname: "actionlint"},
		{pname: "shellcheck"},
		{pname: "hadolint"},
		pkgs.ruff,
		pkgs.git,
		// libstdc++ for the wheels linking it (grpcio, numpy, pyarrow): nix's Python doesn't
		// search the host's library dirs. Its lib output only: the package's unwrapped gcc
		// can't link (it knows no libc).
		{pname: "gcc-unwrapped", attr: "gcc-unwrapped.lib"},
		// The rust builds' native parts (openssl-src, librdkafka, aws-lc, tonic-build), which ran
		// the host's cc, make and perl and found no protoc or openssl at all. CI's runners have
		// build-essential and install libssl-dev, pkg-config and protoc. macOS has its own cc.
		{pname: "gcc", platforms: ["linux"]},
		{pname: "binutils", platforms: ["linux"]},
		{pname: "gnumake"},
		{pname: "perl"},
		{pname: "pkg-config"},
		{pname: "openssl", attr: "openssl.dev"},
		// The linker rust/.cargo/config.toml names for Apple Silicon (`-fuse-ld=lld`, which
		// clang resolves to ld64.lld on PATH); upstream's flox env installs it there only.
		// 23.1.3 or newer: older ones can't read the macOS 27 SDK's .tbd stubs.
		{pname: "lld", attr: "llvmPackages_23.lld", version: "23.1.3", platforms: ["aarch64-darwin"]},
		// libomp for xgboost's macOS wheel (dagster's signals tests import it), which looks for it
		// at Homebrew's prefix only; Linux wheels load libgomp from gcc-unwrapped.lib above.
		{pname: "openmp", attr: "llvmPackages.openmp", libraries: true, platforms: ["aarch64-darwin"]},
		// ci-rust.yml's test runner (it installs cargo-nextest 0.9.140, which no snapshot has
		// next to the pins above) and the jq its doctest step lists lib packages with.
		{pname: "cargo-nextest"},
		{pname: "jq"},
		// The Storybook test-runner's browser (storybook:test): Playwright's chromium builds at
		// the revision the locked playwright (pnpm-lock.yaml, 1.60.0) looks up, as upstream's
		// ghcr.io/posthog/playwright:v1.60.0 image has them. It exports PLAYWRIGHT_BROWSERS_PATH.
		pkgs.#PlaywrightBrowsers & {version: "1.60.0", features: ["chromium-headless-shell", "chromium"]},
		// ci-rust.yml's lint runs `cargo shear` at 1.1.12, from its release binaries (static on
		// Linux): the snapshot's 1.14 also reports dependencies only dev targets use, 5 errors
		// at the pin that upstream's lint never sees.
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
		// protoc: setup-protoc pins 28.3, no snapshot has it next to the pins above.
		{pname: "protobuf"},
		// The persons database's migrations (rust/persons_migrations). CI's setup-sqlx-cli pins
		// 0.8.0, which no snapshot has alongside the pins above.
		{pname: "sqlx-cli"},
		// As upstream's flox manifest: the test databases' locks (test_databases.sh's flock), and
		// hogli's build:openapi's setsid (openapi_types' schema check). Linux hosts have both,
		// macOS neither.
		{pname: "util-linux"},
		// The seaweedfs preset's readiness probe, and bin/download-mmdb's download and decompression.
		{pname: "curl"},
		{pname: "brotli"},
		// The Azure blob emulator upstream's backend jobs start (objectstorage-azure).
		{pname: "azurite"},
		// docker-compose.base.yml's dynamodb (amazon/dynamodb-local:3.3.1), which ci-nodejs.yml
		// starts: AWS's release archive (nixpkgs' dynamodb-local is unfree, so no binary cache
		// has it), run on the env's JDK. The dated archive is the `v3.x/dynamodb_local_latest`
		// that held 3.3.1; `latest` moves. One archive for every platform: its DynamoDBLocal_lib
		// holds sqlite4java's natives for each.
		{pname: "jdk21_headless"},
		schema.#ArchiveBuildSpec & {
			pname:   "dynamodb-local"
			version: "3.3.1"
			src:     "https://d1ni2b6xgvw0s0.cloudfront.net/v3.x/dynamodb_local_2026-07-31.tar.gz"
			sha256:  "f80bcec477f85f57e2c77f8d54aa6b672a8403fceff0c450560aee1cf6c21163"
			// The launcher finds the jar beside itself, wherever the store is.
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
		// The coordination store ci-rust.yml's compose `etcd` profile starts (personhog, kafka-assigner).
		{pname: "etcd"},
		// What the helpers run besides, resolved inside `enve run` (else the host's: macOS's
		// bash 3.2, BSD tools): run_sharded_pytest.sh's and setup.sh's `rg`, `mapfile` (bash
		// 4+) in the showcase scripts, test_databases.sh's `sha256sum` and `nproc`.
		{pname: "ripgrep"},
		{pname: "bash"},
		{pname: "coreutils"},
		// GNU sed, as upstream's ubuntu runners: .github/scripts' tests (bump_quotes_the_tarball_
		// digest) pass it a script BSD sed rejects ("extra characters at the end of D command").
		{pname: "gnused"},
	]

	environment: {
		// As upstream's containers and CI runners: a host's TZ shifts ClickHouse's and the
		// tests' dates (test_query_joins_pdi_persons, one hour off under CEST).
		TZ:   "UTC"
		PGTZ: "UTC"
		// What every job may see, as ci-backend.yml's global DATABASE_URL. The test databases a job
		// uses are its runner's to name (test_databases.sh for the backend's shards, run_nodejs_tests.sh,
		// run_rust_tests.sh): set here, the nodejs setup's `migrate-entry --fresh` reset the backend's
		// persons template (PERSONS_DATABASE_URL), and the nodejs suite refused the dev database.
		DATABASE_URL:                     "postgres://posthog:posthog@127.0.0.1:${ENVE_SERVICE_POSTGRES_PORT}/posthog"
		PGHOST:                           "127.0.0.1"
		PGPORT:                           "${ENVE_SERVICE_POSTGRES_PORT}"
		PGUSER:                           "posthog"
		PGPASSWORD:                       "posthog"
		PGDATABASE:                       "posthog"
		POSTHOG_DB_USER:                  "posthog"
		POSTHOG_DB_PASSWORD:              "posthog"
		POSTHOG_POSTGRES_HOST:            "127.0.0.1"
		POSTHOG_POSTGRES_PORT:            "${ENVE_SERVICE_POSTGRES_PORT}"
		REDIS_URL:                        "redis://127.0.0.1:${ENVE_SERVICE_REDIS_PORT}"
		REDIS_PORT:                       "${ENVE_SERVICE_REDIS_PORT}"
		CLICKHOUSE_HOST:                  "127.0.0.1"
		CLICKHOUSE_HTTP_PORT:             "${ENVE_SERVICE_CLICKHOUSE_PORT}"
		CLICKHOUSE_TCP_PORT:              "${ENVE_SERVICE_CLICKHOUSE_PORT_NATIVE}"
		CLICKHOUSE_DATABASE:              "test_posthog"
		CLICKHOUSE_TEST_CLUSTER_HOST:     "127.0.0.1"
		CLICKHOUSE_TEST_CLUSTER_DATABASE: "posthog_test"
		// The logs cluster's client (usage reports' logs and metrics queries) dials
		// localhost:9000 by default, CI's Docker port: the run's ClickHouse is on its own.
		CLICKHOUSE_LOGS_CLUSTER_HOST: "127.0.0.1"
		CLICKHOUSE_LOGS_CLUSTER_PORT: "${ENVE_SERVICE_CLICKHOUSE_PORT_NATIVE}"
		KAFKA_HOSTS:                  "127.0.0.1:${ENVE_SERVICE_KAFKA_PORT}"
		KAFKA_URL:                    "127.0.0.1:${ENVE_SERVICE_KAFKA_PORT}"
		TEMPORAL_HOST:                "127.0.0.1"
		TEMPORAL_PORT:                "${ENVE_SERVICE_TEMPORAL_PORT}"
		TEMPORAL_ADDRESS:             "127.0.0.1:${ENVE_SERVICE_TEMPORAL_PORT}"
		OBJECT_STORAGE_ENABLED:       "True"
		// The test process's endpoint is `localhost`, as upstream's CI sets it: the presigned-URL
		// tests (posthog/storage/test/test_object_storage.py) match `^http://localhost:\d+/`.
		// The endpoints ClickHouse reaches (below) stay 127.0.0.1.
		OBJECT_STORAGE_ENDPOINT:           "http://localhost:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		OBJECT_STORAGE_ACCESS_KEY_ID:      "object_storage_root_user"
		OBJECT_STORAGE_SECRET_ACCESS_KEY:  "object_storage_root_password"
		NOTEBOOKS_FRAME_STORE_S3_ENDPOINT: "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		// Endpoints ClickHouse itself reaches (s3() staging): upstream's CI maps objectstorage to
		// 127.0.0.1 in /etc/hosts, which a rootless environment can't, so they're set to it here.
		BATCH_EXPORT_OBJECT_STORAGE_ENDPOINT: "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		IDENTITY_MATCHING_S3_ENDPOINT:        "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		DICTIONARY_STAGING_S3_ENDPOINT:       "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		DATA_DELETION_STAGING_S3_ENDPOINT:    "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		DATAWAREHOUSE_BUCKET_DOMAIN:          "127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		// The hosts ClickHouse's postgresql() and web analytics' s3() reach, which upstream
		// hardcodes as compose names (db, objectstorage) and its CI maps in /etc/hosts. macOS's
		// resolver has no rootless alias (HOSTALIASES is glibc's): patches/0001 reads these.
		CLICKHOUSE_POSTGRES_HOST:       "127.0.0.1"
		CLICKHOUSE_OBJECT_STORAGE_HOST: "127.0.0.1"
		// The identity store's, as enve exports for an env's one object store: with seaweedfs-open
		// beside it enve names neither and warns. The pytest and Rust runners unset it, as CI's
		// test env has none (run_sharded_pytest.sh, rust_ci_env.sh).
		AWS_ENDPOINT_URL: "http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT}"
		// The Azure blob emulator's port, which the azure_blob tests' connection string reads
		// (patches/0001-service-ports-from-env.patch).
		AZURITE_BLOB_PORT:                 "${ENVE_SERVICE_AZURITE_PORT}"
		SECRET_KEY:                        "6b01eee4f945ca25045b5aab440b953461faf08693a9abbf1166dc7c6b9772da"
		DJANGO_SECRET_KEY:                 "6b01eee4f945ca25045b5aab440b953461faf08693a9abbf1166dc7c6b9772da"
		DEBUG:                             "0"
		TEST:                              "1"
		SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
		// pnpm runs as locked, not the packageManager version it would download.
		npm_config_manage_package_manager_versions: "false"
		// turbo's strict env mode hands a task only the variables turbo.json names: pnpm under
		// `turbo test` (packages/agent) lost the line above and the CA bundle variables, and failed
		// downloading pnpm@10.23.0 (UNABLE_TO_GET_ISSUER_CERT_LOCALLY). Loose passes the env on;
		// cache keys still hash only the named variables. CI's pnpm is the packageManager one.
		TURBO_ENV_MODE:                  "loose"
		COREPACK_ENABLE_DOWNLOAD_PROMPT: "0"
		NO_PROXY:                        "127.0.0.1,localhost,::1"
	}

	services: {
		postgres: {
			database: "posthog"
			user:     "posthog"
			port:     5432
			// As docker-compose.dev.yml's db, which every CI job runs: the nodejs suite's four jest
			// workers open more than the default 100 connections ("sorry, too many clients already").
			command: "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -p $PORT -c max_connections=1000 -c idle_in_transaction_session_timeout=300000 -c max_prepared_transactions=10"
			lifecycle: init: [
				// UTF-8 collation as upstream's postgres image (LANG en_US.utf8), not the preset's C:
				// SCIM and login fold addresses with Postgres LOWER, which under C leaves `İ` as is
				// (ee/api/scim/test/test_users_api.py, ee/api/test/test_authentication.py). Applies
				// to a fresh data directory only (initdb).
				"initdb -D \"$DATA_DIR\" -U postgres --auth-local=trust --auth-host=trust --locale=C.UTF-8 --encoding=UTF8",
			]
		}
		redis: {
			// Databases by suite (showcase/scripts/test_databases.sh): 0 Rust, 1 Rust's dedicated
			// flags Redis, 2 Rust's ignored tests' (cymbal's flush theirs), 3 the Rust /flags
			// integration tests' (run_flags_integration.sh), 16+n a Python shard's, 32+n its
			// AI-gateway tests' (they flush theirs); a nodejs shard has an instance of its own
			// (run_nodejs_tests.sh). No FLAGS_REDIS_URL, as upstream's CI: a fixed one is every
			// shard's.
			// In memory only, as upstream's redis7 container (no volume), fresh each CI job: a dump
			// kept across runs serves a recreated test database's reused team ids their previous
			// run's cache entries (feature-flags test_flag_definitions' cache-miss tests answer 200).
			command: "rm -f \"$DATA_DIR/dump.rdb\" && exec redis-server --port $PORT --dir \"$DATA_DIR\" --daemonize no --databases 48 --save '' --appendonly no"
		}
		// As docker-compose.dev.yml's valkey-cluster, which ci-rust.yml's test job starts: one
		// cluster-enabled node holding every slot (usage-ingestion's counters tests). The env's
		// redis-server, not valkey 8.1: the same protocol and cluster commands. Fresh each start,
		// as the container's /tmp/nodes.conf. The cluster bus is a port slot of its own (else
		// port+10000, outside a named instance's port range).
		"valkey-cluster": {
			port: 6390
			ports: bus: 16390
			command: "rm -f \"$DATA_DIR/nodes.conf\" && exec redis-server --port $PORT --cluster-port $PORT_BUS --dir \"$DATA_DIR\" --daemonize no --save '' --appendonly no --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000"
			readinessProbe: command: "redis-cli -p $PORT ping"
			lifecycle: postStart:    "redis-cli -p $PORT cluster addslots $(seq 0 16383) >/dev/null && until redis-cli -p $PORT cluster info | rg -q '^cluster_state:ok'; do sleep 0.1; done"
		}
		clickhouse: {
			// It loads the persisted test databases synchronously (config.xml's async_load_databases):
			// ~20s with a dozen shards' posthog_test_shardN.
			timeout: "90s"
			// Every listener a slot of its own, so a named instance (E7) gets free ones: the config
			// reads them from the server's $PORT_<SLOT> (from_env). start.sh renders the config's
			// data dir and checkout paths, which differ per instance, and lays this platform's
			// profile overrides over upstream's users (macOS: no JIT).
			ports: {native: 9000, interserver: 9009, keeper: 9181, raft: 9234}
			files: {
				"config.template.xml": {
					source: "infra/clickhouse/config.xml"
				}
			}
			command: "infra/clickhouse/start.sh"
			lifecycle: {
				// On macOS, the UDFs as host binaries (posthog/user_scripts commits Linux ones): built
				// once per source state, under a lock every instance's start shares.
				preStart: {
					run:     "showcase/scripts/exclusive.sh clickhouse-host-udfs infra/clickhouse/build_host_udfs.sh"
					timeout: "10m"
				}
				postStart: "clickhouse-client --port $PORT_NATIVE -q 'SELECT 1; SYSTEM FLUSH LOGS;'"
			}
		}
		// Upstream's broker is Redpanda, whose group_initial_rebalance_delay keeps its 3 s default
		// (compose and dev-container mode leave it; Apache Kafka's default is the same). enve's preset
		// sets 0, and ingestion-consumer's e2e tests then race: a fresh group's consumer streams
		// the 4 messages they produce one by one instead of fetching them in one batch.
		// group.min.session.timeout.ms admits the 3 s sessions ClickHouse's Kafka tables ask for
		// (infra/clickhouse/config.xml: a dropped table's consumer stays a member until it expires).
		kafka: command: "cd \"$DATA_DIR\" && exec kafka-server-start.sh server.properties --override group.initial.rebalance.delay.ms=3000 --override group.min.session.timeout.ms=3000"
		temporal: {}
		// As docker-compose.base.yml's objectstorage: volumes that grow on demand (the tests make a
		// bucket each), and the identities and buckets its bootstrap loop registers.
		seaweedfs: {
			// Each listener a port slot (`weed server`'s defaults), so a named instance (E7) gets free ones.
			port: 19000
			ports: {master: 19001, volume: 19002, filer: 8888, s3_grpc: 29000, master_grpc: 29001, volume_grpc: 29002, filer_grpc: 18888}
			command: "weed server -ip=127.0.0.1 -master.raftHashicorp -s3 -s3.port=$PORT -s3.port.grpc=$PORT_S3_GRPC -s3.port.iceberg=0 -s3.port.lance=0 -master.port=$PORT_MASTER -master.port.grpc=$PORT_MASTER_GRPC -volume.port=$PORT_VOLUME -volume.port.grpc=$PORT_VOLUME_GRPC -filer.port=$PORT_FILER -filer.port.grpc=$PORT_FILER_GRPC -dir=\"$DATA_DIR\" -volume.max=1000 -master.volumePreallocate=false"
			lifecycle: postStart: {
				run:     "bash showcase/scripts/seaweedfs_setup.sh"
				timeout: "90s"
			}
		}
		// As docker-compose.base.yml's seaweedfs (:8333), which ci-nodejs.yml starts next to
		// objectstorage: open access, no identities, so any credentials sign and a put to a
		// missing bucket is refused. An identity store (the one above) can't stand in: an admin
		// key's put creates the missing bucket, a plain key can't create one (blob-store's
		// integration test). Session replay's and the AI blob store's tests reach it.
		"seaweedfs-open": schema.#SeaweedfsService & {
			port: 8333
			ports: {master: 9333, volume: 18080, filer: 18889, s3_grpc: 28333, master_grpc: 19333, volume_grpc: 28080, filer_grpc: 28889}
			command: "weed server -ip=127.0.0.1 -master.raftHashicorp -s3 -s3.port=$PORT -s3.port.grpc=$PORT_S3_GRPC -s3.port.iceberg=0 -s3.port.lance=0 -master.port=$PORT_MASTER -master.port.grpc=$PORT_MASTER_GRPC -volume.port=$PORT_VOLUME -volume.port.grpc=$PORT_VOLUME_GRPC -filer.port=$PORT_FILER -filer.port.grpc=$PORT_FILER_GRPC -dir=\"$DATA_DIR\" -volume.max=1000 -master.volumePreallocate=false"
		}
		// As docker-compose.profiles.yml's etcd, which ci-rust.yml starts (COMPOSE_PROFILES: etcd):
		// the store the personhog coordination, personhog-leader and kafka-assigner tests use.
		etcd: {
			port: 2379
			ports: peer: 2380
			command: "etcd --name default --data-dir \"$DATA_DIR\" --listen-client-urls http://127.0.0.1:$PORT --advertise-client-urls http://127.0.0.1:$PORT --listen-peer-urls http://127.0.0.1:$PORT_PEER --initial-advertise-peer-urls http://127.0.0.1:$PORT_PEER --initial-cluster default=http://127.0.0.1:$PORT_PEER"
			readinessProbe: command: "etcdctl --endpoints=http://127.0.0.1:$PORT endpoint health"
		}
		// As docker-compose.base.yml's dynamodb, which ci-nodejs.yml starts (its flags): session
		// replay's recording API and the ML mirror's crawl history integration tests reach it
		// (DYNAMODB_ENDPOINT, patches/0001). It answers GET / with a 400, which curl without -f
		// takes as up.
		dynamodb: {
			port:    18010
			command: "dynamodb-local -inMemory -sharedDb -disableTelemetry -port $PORT"
			readinessProbe: command: "curl -s -o /dev/null http://127.0.0.1:$PORT/"
			timeout: "60s"
		}
		// As docker-compose.base.yml's maildev (maildev/maildev:2.0.5), which ci-nodejs.yml starts:
		// the CDP's email tests send through its SMTP and read its web API's /email (MAILDEV_PORT,
		// MAILDEV_WEB_PORT). maildev 2.0.5 from npm with a lockfile of its own (infra/maildev),
		// installed once per lockfile into the checkout; mailpit's API differs.
		maildev: {
			port: 1080
			ports: smtp: 1025
			command: "node infra/maildev/node_modules/maildev/bin/maildev --ip 127.0.0.1 --web $PORT --smtp $PORT_SMTP --mail-directory \"$DATA_DIR\" --silent"
			readinessProbe: path: "/healthz"
			lifecycle: preStart: {
				run:     "showcase/scripts/exclusive.sh maildev-node-modules bash infra/maildev/install.sh"
				timeout: "5m"
			}
		}
		// As docker-compose.base.yml's objectstorage-azure (Azurite's blob service), which the
		// backend jobs start: batch_exports' Azure Blob destination tests reach it on AZURITE_BLOB_PORT
		// (their connection string, the emulator's well-known account; patches/0001).
		azurite: {
			command: "azurite-blob --blobHost 127.0.0.1 --blobPort $PORT --location \"$DATA_DIR\""
			port:    10000
			// Ready once it answers HTTP (400 for "/", which passes: below 500), not once its
			// port merely accepts.
			readinessProbe: path: "/"
			timeout: "30s"
		}
	}
}
