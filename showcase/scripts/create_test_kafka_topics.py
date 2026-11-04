#!/usr/bin/env python3
# ruff: noqa: T201, B007
"""
Creates the Kafka topics one backend test worker writes (`--worker shard1`).
Fails when the broker is unreachable.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from confluent_kafka import KafkaError, KafkaException
from confluent_kafka.admin import AdminClient, NewTopic

# The topics the code produces to. Every topic a ClickHouse Kafka table consumes is read from
# upstream's own list (docker/kafka/topics.txt, which posthog/clickhouse/test/test_schema.py keeps
# in step with schema.py) rather than copied here.
BASE_TOPICS = [
    "clickhouse_events_json",
    "exceptions_ingestion",
    "events_plugin_ingestion",
    "events_plugin_ingestion_overflow",
    "events_plugin_ingestion_historical",
    "clickhouse_person",
    "clickhouse_person_unique_id",
    "clickhouse_person_distinct_id",
    "clickhouse_performance_events",
    "plugin_log_entries",
    "events_dead_letter_queue",
    "clickhouse_groups",
    "clickhouse_ingestion_warnings",
    "clickhouse_app_metrics",
    "clickhouse_app_metrics2",
    "clickhouse_metrics_time_to_see_data",
    "clickhouse_person_override",
    "log_entries",
    "log_entries_v2_test",
    "clickhouse_hog_invocation_results",
    "clickhouse_message_assets",
    "clickhouse_heatmap_events",
    "clickhouse_ai_events_json",
    "clickhouse_flag_evaluations",
    "session_recording_events",
    "clickhouse_session_replay_events",
    "clickhouse_session_replay_features",
    "clickhouse_session_recording_events",
    "clickhouse_error_tracking_issue_fingerprint",
    "clickhouse_error_tracking_fingerprint_issue_state",
    "clickhouse_error_tracking_issue_fingerprint_embeddings",
    "clickhouse_document_embeddings",
    "document_embeddings_input",
    "document_embedding_results",
    "cdp_internal_events",
    "cdp_backfill_events",
    "cohort_membership_changed",
    "cdp_data_warehouse_source_table",
    "data_warehouse_source_webhooks",
    "data_warehouse_source_webhooks_dlq",
    "clickhouse_tophog",
    "clickhouse_billing_usage_records",
    "distinct_id_usage_events_json",
    "clickhouse_property_values",
    "clickhouse_precalculated_person_properties",
    "clickhouse_prefiltered_events",
    "notification_events",
    "signals_report_completed",
    "flags_cache_invalidation",
    "flags_cache_invalidation_dlq",
    "warehouse_person_property_updates",
    "warehouse_person_property_updates_dlq",
    "logs_ingestion",
    "logs_ingestion_dlq",
    "ingestion-traces",
    "ingestion-traces-dlq",
]

# Brokers auto-create topics with one partition (redpanda in upstream's compose, kafka's
# num.partitions=1 under enve): pre-creating them as such only takes the first produce's wait.
PARTITIONS = 1


UPSTREAM_TOPICS = Path(__file__).resolve().parents[2] / "docker/kafka/topics.txt"


def listed_topics(listing: Path = UPSTREAM_TOPICS) -> set[str]:
    lines = (line.strip() for line in listing.read_text().splitlines())
    return {line for line in lines if line and not line.startswith("#")}


def topic_names(listing: Path = UPSTREAM_TOPICS) -> list[str]:
    return sorted(listed_topics(listing) | set(BASE_TOPICS))


def worker_topics(worker: str | None, listing: Path = UPSTREAM_TOPICS) -> list[str]:
    """The topics a test worker uses, named as posthog/settings/data_stores.py (and nodejs's
    kafka-topics.ts) suffix them: `_test`, plus `_<PYTEST_XDIST_WORKER>` when the worker sets one.
    Besides, topics.txt's own names, as docker-compose's kafka-init creates them: a few Kafka
    tables name their topic with no suffix (kafka_metrics_avro4's clickhouse_metrics,
    kafka_precalculated_events' clickhouse_prefiltered_events), and on a broker without them
    those tables never get a partition."""
    suffix = "_test" + (f"_{worker}" if worker else "")
    return sorted({f"{topic}{suffix}" for topic in topic_names(listing)} | listed_topics(listing))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", help="the PYTEST_XDIST_WORKER the topics are suffixed with")
    # No fixed default: a named service instance (E7) runs Kafka on a port of its own, and a
    # fixed one would reach another run's broker.
    parser.add_argument(
        "--broker",
        default=os.environ.get("KAFKA_HOSTS", "").split(",")[0],
        help="bootstrap server (default: the first of $KAFKA_HOSTS)",
    )
    args = parser.parse_args(argv)
    if not args.broker:
        parser.error("no broker: pass --broker or set KAFKA_HOSTS")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    admin = AdminClient({"bootstrap.servers": args.broker, "socket.timeout.ms": 5000})
    try:
        existing = admin.list_topics(timeout=10).topics
    except Exception as e:
        print(f"Kafka broker {args.broker} is unreachable: {e}", file=sys.stderr)
        return 1

    missing = [t for t in worker_topics(args.worker) if t not in existing]
    if not missing:
        return 0
    futures = admin.create_topics([NewTopic(t, num_partitions=PARTITIONS, replication_factor=1) for t in missing])
    failed = 0
    for topic, future in futures.items():
        try:
            future.result(timeout=30)
        except KafkaException as e:
            if e.args[0].code() != KafkaError.TOPIC_ALREADY_EXISTS:
                print(f"Could not create topic {topic}: {e}", file=sys.stderr)
                failed += 1
    print(f"Created {len(missing) - failed}/{len(missing)} Kafka topics on {args.broker}.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
