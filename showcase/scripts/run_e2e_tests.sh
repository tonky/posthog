#!/usr/bin/env bash
# ci-e2e-playwright.yml's "Playwright E2E tests": a whole PostHog booted for end-to-end testing
# (E2E_TESTING, TEST unset) on the run's services, then Playwright's chromium (the env's
# browsers, PLAYWRIGHT_BROWSERS_PATH) driving it through the specs. As upstream: the frontend
# built (build_e2e.sh, the job's task before) and its static files collected, the databases migrated (Django, persons, ClickHouse),
# personhog's replica and router, setup_dev's user, a Celery worker, the Temporal worker and
# granian, Rust capture (its analytics and AI deployments, behind a proxy as compose's) and the
# Node.js event ingestion, then `playwright test` with CI's
# settings (one retry, --update-snapshots: capture-only, Visual Review compares). The spec
# files narrow the run, as upstream's selective mode; none runs them all.
#
#   run_e2e_tests.sh [spec files...]
#
# Everything the job starts is its own (live_posthog.sh): databases, a ClickHouse database,
# Kafka topics under its prefix, Redis database 5, and a free port per listener (upstream's
# 8000, 3307 and 6738-6746 are fixed). Its reports, artifacts and screenshots go to
# .enact/state/e2e (patches/0008), never beside the specs.
#
# Recording footprints for enact (ENACT_FOOTPRINT_DIR set): each spec runs alone, against
# Django, Celery and the Temporal worker started afresh for it (live_each_spec,
# live_footprint.py); the frontend's build writes what each output was made from.
#
# Not started (upstream's compose profiles start them): the plugin server's CDP and the session
# replay, recording API, error tracking, logs and traces consumers.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# enact gives the specs relative to the task's directory; Playwright matches them against
# absolute paths, so they go from the checkout's root, as upstream's selection names them.
specs=()
for spec in "$@"; do
    spec="$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")"
    specs+=("${spec#"$root"/}")
done
cd "$root"
# shellcheck source=test_databases.sh
source showcase/scripts/test_databases.sh
# shellcheck source=live_posthog.sh
source showcase/scripts/live_posthog.sh

# The builds ("Install plugin_transpiler", the frontend's prepare, "Build frontend" and the
# ingestion's Node.js build) ran in the job's task before this one (build_e2e.sh).

results="$root/.enact/state/e2e"
live_setup "${ENACT_COMPONENT:-e2e}" "${ENACT_JOB:-test}" 5 "$results/logs"
capture_port=$(live_free_port) capture_ai_port=$(live_free_port) proxy_port=$(live_free_port)
ingestion_port=$(live_free_port)
site="http://localhost:$live_web_port"
# ci-e2e-playwright.yml's own environment.
live_run+=(E2E_TESTING=1 OPT_OUT_CAPTURE=0 CLOUD_DEPLOYMENT=E2E SITE_URL="$site" SECURE_COOKIES=0
    EMAIL_HOST=email.test.posthog.net OBJECT_STORAGE_ENABLED=1)
# Django's capture_internal (a person property's edit and delete, ...) and capture_ai_internal
# post to upstream's localhost:8010, compose's proxy in front of capture and capture-ai; here
# the job's proxy (below).
proxy="http://127.0.0.1:$proxy_port"
live_run+=(CAPTURE_INTERNAL_URL="$proxy" CAPTURE_AI_INTERNAL_URL="$proxy")

# "Collect static files without compression": Django serves the built bundle from them.
showcase/scripts/exclusive.sh collectstatic "${live_run[@]}" STATIC_PRECOMPRESS=0 \
    uv run --no-sync python manage.py collectstatic --noinput >"$live_logs/collectstatic.log"
# Recording, from here on (collectstatic copies the whole bundle: what a spec's page fetched
# counts, by WhiteNoise's reads).
live_record
if [ -n "$live_recording" ] && [ ${#specs[@]} -eq 0 ]; then
    mapfile -t specs < <(git ls-files ':(glob)playwright/e2e/**/*.spec.ts' ':(glob)products/*/frontend/e2e/**/*.spec.ts')
fi

# "Apply postgres and clickhouse migrations and setup dev" (the persons database is the
# template's clone, migrated as upstream's sqlx step migrates its own).
live_topics
live_migrate
live_build_rust capture personhog-replica personhog-router
live_start_personhog
live_py manage.py setup_dev >"$live_logs/setup_dev.log"

# "Start PostHog web, Celery worker, Temporal worker & ingestion": capture, capture-ai, the
# ingestion and the proxy here, the app's Python processes by e2e_app below.
# compose's capture and capture-ai (docker-compose.base.yml): one binary, whose CAPTURE_MODE
# picks the routes it mounts (ai: /i/v0/ai/batch/ and the rest of the AI lane), its topics
# under the job's prefix. Its v1 sink mounts /i/v1/analytics/events (ai: /i/v1/ai/events),
# where Django's capture_internal posts (else a 404).
prefix="${live_worker}_"
e2e_capture() { # <name> <port> <mode> <main topic> <v1 historical topic> <v1 overflow topic>
    live_start "$1" "$2" "http://127.0.0.1:$2/_liveness" "${live_run[@]}" \
        ADDRESS="127.0.0.1:$2" KAFKA_HOSTS="$KAFKA_HOSTS" \
        KAFKA_INGESTION_PRODUCER_METADATA_BROKER_LIST="$KAFKA_HOSTS" CAPTURE_MODE="$3" \
        KAFKA_TOPIC="${prefix}$4" KAFKA_ERROR_TRACKING_TOPIC="${prefix}ingestion-errortracking-main" \
        KAFKA_OVERFLOW_TOPIC="${prefix}events_plugin_ingestion_overflow" \
        KAFKA_HISTORICAL_TOPIC="${prefix}events_plugin_ingestion_historical" \
        KAFKA_DLQ_TOPIC="${prefix}events_plugin_ingestion_dlq" KAFKA_HEATMAPS_TOPIC="${prefix}heatmaps_ingestion" \
        KAFKA_CLIENT_INGESTION_WARNING_TOPIC="${prefix}ingestion-clientwarnings-main-1" \
        CAPTURE_ANALYTICS_AI_EVENTS_TOPIC="${prefix}events_plugin_ingestion_ai" \
        CAPTURE_V1_SINKS=msk CAPTURE_V1_SINK_MSK_KAFKA_HOSTS="$KAFKA_HOSTS" \
        CAPTURE_V1_SINK_MSK_KAFKA_TOPIC_MAIN="${prefix}$4" \
        CAPTURE_V1_SINK_MSK_KAFKA_TOPIC_HISTORICAL="${prefix}$5" \
        CAPTURE_V1_SINK_MSK_KAFKA_TOPIC_OVERFLOW="${prefix}$6" \
        CAPTURE_V1_SINK_MSK_KAFKA_TOPIC_DLQ="${prefix}events_plugin_ingestion_dlq" \
        CAPTURE_V1_SINK_MSK_KAFKA_TOPIC_EXCEPTION="${prefix}ingestion-errortracking-main" \
        CAPTURE_V1_SINK_MSK_KAFKA_TOPIC_HEATMAP="${prefix}heatmaps_ingestion" \
        CAPTURE_V1_SINK_MSK_KAFKA_TOPIC_CLIENT_INGESTION_WARNING="${prefix}ingestion-clientwarnings-main-1" \
        RUST_LOG='info,rdkafka=warn' "$live_bin/capture"
}
e2e_capture capture "$capture_port" events events_plugin_ingestion events_plugin_ingestion_historical \
    events_plugin_ingestion_overflow
e2e_capture capture-ai "$capture_ai_port" ai events_plugin_ingestion_ai events_plugin_ingestion_ai \
    events_plugin_ingestion_ai
# compose's ingestion-general: the posthog-node image's `node nodejs/dist/index.js`, built as
# the image builds it (build_e2e.sh). Its consumers and each producer slot take their brokers
# from variables of their own, else compose's `kafka:9092`.
brokers=()
for client in CONSUMER PRODUCER INGESTION_UPSTREAM_PRODUCER INGESTION_DOWNSTREAM_PRODUCER WAREHOUSE_PRODUCER \
    WARPSTREAM_INGESTION_PRODUCER WARPSTREAM_CYCLOTRON_PRODUCER WARPSTREAM_LOGS_PRODUCER WARPSTREAM_METRICS_PRODUCER; do
    brokers+=("KAFKA_${client}_METADATA_BROKER_LIST=$KAFKA_HOSTS")
done
LIVE_TRIES=90 live_start ingestion-general "$ingestion_port" "http://127.0.0.1:$ingestion_port/_ready" \
    "${live_run[@]}" "${brokers[@]}" NODE_ENV=production PLUGIN_SERVER_MODE=ingestion-v2-combined HTTP_SERVER_PORT="$ingestion_port" \
    PERSONS_DATABASE_URL="$live_persons" BEHAVIORAL_COHORTS_DATABASE_URL="$live_database" \
    CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_SECURE=false CLICKHOUSE_VERIFY=false \
    COOKIELESS_REDIS_HOST=127.0.0.1 CDP_REDIS_HOST=127.0.0.1 PERSONHOG_ENABLED=true \
    ENCRYPTION_SALT_KEYS=00beef0000beef0000beef0000beef00 SITE_URL="$site" \
    AI_BLOB_S3_BUCKET=ai-blobs AI_BLOB_S3_PREFIX=aio/ AI_BLOB_S3_ENDPOINT="http://127.0.0.1:$ENVE_SERVICE_SEAWEEDFS_PORT" \
    AI_BLOB_S3_REGION=us-east-1 AI_BLOB_S3_ACCESS_KEY_ID=object_storage_root_user \
    AI_BLOB_S3_SECRET_ACCESS_KEY=object_storage_root_password AI_BLOB_OFFLOAD_TEAMS='*' \
    node nodejs/dist/index.js
# compose's proxy (Caddy, upstream's localhost:8010) as far as the job reaches it: its capture-ai
# paths to capture-ai, its capture paths to capture, the rest to the web server.
LIVE_TRIES=15 live_start proxy "$proxy_port" - env PORT="$proxy_port" AI="$capture_ai_port" EVENTS="$capture_port" \
    WEB="$live_web_port" node --input-type=module -e '
import http from "node:http"
const ai = /^\/i\/v0\/ai(\/|$)|^\/i\/v1\/ai\/events\/?$/
const events = /^\/e(\/|$)|^\/i\/v0\/|^\/i\/v1\/analytics\/events\/?$|^\/batch|^\/capture/
const port = (path) => (ai.test(path) ? process.env.AI : events.test(path) ? process.env.EVENTS : process.env.WEB)
http.createServer((req, res) => {
    const options = { host: "127.0.0.1", port: port(req.url.split("?")[0]), path: req.url, method: req.method, headers: req.headers }
    const upstream = http.request(options, (answer) => {
        res.writeHead(answer.statusCode, answer.headers)
        answer.pipe(res)
    })
    upstream.on("error", (error) => res.writeHead(502).end(String(error)))
    req.pipe(upstream)
}).listen(Number(process.env.PORT), "127.0.0.1")
'
# Upstream's 6 Playwright and 4 granian workers on 8 cores, scaled to the CPUs enact admitted
# the job with (ENACT_WORKER_CPUS: 6 on a tonky-ci slot gives 4 and 3), at least one each.
if [ -n "${ENACT_WORKER_CPUS:-}" ]; then
    cpus=${ENACT_WORKER_CPUS%.*}
    [ "${cpus:-0}" -ge 1 ] 2>/dev/null || cpus=1
    : "${PLAYWRIGHT_WORKERS:=$(( cpus * 3 / 4 > 0 ? cpus * 3 / 4 : 1 ))}"
    : "${GRANIAN_WORKERS:=$(( cpus / 2 > 0 ? cpus / 2 : 1 ))}"
fi
e2e_app() {
    live_start_celery
    live_start temporal-worker 0 - "${live_run[@]}" uv run --no-sync python manage.py start_temporal_worker \
        --task-queue analytics-platform-task-queue
    live_start_web "${GRANIAN_WORKERS:-4}"
}

# "Run Playwright tests".
e2e_run() { # [spec...]
    (cd playwright && CI=1 BASE_URL="$site" E2E_PROXY_URL="$proxy" PLAYWRIGHT_RETRIES=1 \
        PLAYWRIGHT_RESULTS_DIR="$results/run" pnpm exec playwright test "$@" \
        --workers="${PLAYWRIGHT_WORKERS:-6}" --update-snapshots)
}
rm -rf "$results/run" && mkdir -p "$results/run"
live_each_spec e2e_app e2e_run ${specs[@]+"${specs[@]}"}
