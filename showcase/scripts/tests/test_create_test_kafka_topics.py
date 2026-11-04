import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

# The arguments and names need no broker client: stub it where the env has none.
if importlib.util.find_spec("confluent_kafka") is None:
    kafka = types.ModuleType("confluent_kafka")
    kafka.KafkaError = kafka.KafkaException = Exception
    admin = types.ModuleType("confluent_kafka.admin")
    admin.AdminClient = admin.NewTopic = object
    sys.modules.update({"confluent_kafka": kafka, "confluent_kafka.admin": admin})

spec = importlib.util.spec_from_file_location(
    "create_test_kafka_topics", Path(__file__).resolve().parents[1] / "create_test_kafka_topics.py"
)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CreateTestKafkaTopicsTest(unittest.TestCase):
    def test_worker_flag_is_not_the_broker(self) -> None:
        # test_databases.sh calls `--worker shard1`: the broker once became "--worker".
        with mock.patch.dict(os.environ, {"KAFKA_HOSTS": "127.0.0.1:9092,other:9092"}):
            args = module.parse_args(["--worker", "shard1"])
        self.assertEqual((args.worker, args.broker), ("shard1", "127.0.0.1:9092"))

    def test_topics_carry_the_suffix_the_settings_give_the_worker(self) -> None:
        # posthog/settings/data_stores.py: SUFFIX = "_test" + "_" + PYTEST_XDIST_WORKER.
        with tempfile.TemporaryDirectory() as directory:
            listing = Path(directory) / "topics.txt"
            listing.write_text("# header\n\nclickhouse_logs\n")
            shard = module.worker_topics("shard1", listing)
            self.assertIn("clickhouse_logs_test_shard1", shard)
            self.assertIn("clickhouse_events_json_test_shard1", shard)
            self.assertIn("clickhouse_logs_test", module.worker_topics(None, listing))
            self.assertFalse(any("_gw" in t or "#" in t for t in shard))

    def test_listed_topics_are_created_as_named_too(self) -> None:
        # docker-compose's kafka-init creates topics.txt's names as they are: the Kafka tables
        # that name theirs with no suffix (clickhouse_metrics) never got a partition on a
        # fresh broker, and the nodejs setup waited on them until it timed out.
        with tempfile.TemporaryDirectory() as directory:
            listing = Path(directory) / "topics.txt"
            listing.write_text("# header\n\nclickhouse_metrics\n")
            for worker in (None, "shard1"):
                topics = module.worker_topics(worker, listing)
                self.assertIn("clickhouse_metrics", topics)
                self.assertEqual(len(topics), len(set(topics)))

    @unittest.skipUnless(module.UPSTREAM_TOPICS.is_file(), "needs a PostHog checkout with the overlay")
    def test_every_topic_a_clickhouse_kafka_table_consumes_is_created(self) -> None:
        lines = [line.strip() for line in module.UPSTREAM_TOPICS.read_text().splitlines()]
        listed = {line for line in lines if line and not line.startswith("#")}
        self.assertGreater(len(listed), 10)
        self.assertLessEqual(listed, set(module.topic_names()))


if __name__ == "__main__":
    unittest.main()
