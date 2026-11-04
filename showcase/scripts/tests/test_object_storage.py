"""The object storage accepts the dev credentials, as upstream's objectstorage container does.

seaweedfs started with no identities refused every signed request (AccessDenied), so the
data-warehouse funnel tests failed. Needs the running service and boto3 (the backend's .venv):
`enve run --locked -- .venv/bin/python -m unittest showcase/scripts/tests/test_object_storage.py`.
"""

import json
import os
import socket
import subprocess
import unittest
import uuid
from pathlib import Path

# The env's endpoint only: a fixed default would reach whichever server holds that port (another
# run's, or a VM's forwarded one), not this run's.
ENDPOINT = os.environ.get("OBJECT_STORAGE_ENDPOINT", "")


def reachable() -> bool:
    if not ENDPOINT:
        return False
    host, _, port = ENDPOINT.rsplit("/", 1)[-1].partition(":")
    try:
        socket.create_connection((host, int(port or 80)), timeout=1).close()
        return True
    except OSError:
        return False


try:
    import boto3
except ImportError:
    boto3 = None


class ObjectStorageEnvironmentTest(unittest.TestCase):
    """Service-local credentials cannot turn anonymous readiness into authenticated S3."""

    @classmethod
    def setUpClass(cls) -> None:
        root = Path(__file__).resolve().parents[3]
        env = {**os.environ, "AWS_ACCESS_KEY_ID": "fixture-cache-key", "AWS_SECRET_ACCESS_KEY": "fixture-cache-secret"}

        def exported(expression: str) -> dict:
            out = subprocess.run(
                ["enve", "cue", "export", "-q", "-e", expression, "enve.cue"],
                cwd=root, env=env, capture_output=True, text=True, timeout=30,
            )
            if out.returncode != 0:
                raise AssertionError(f"enve cue export failed: {out.stderr}")
            return json.loads(out.stdout)

        cls.services = exported("profiles.dev.services")
        cls.client_environment = exported("profiles.dev.environment")

    def test_both_fixture_daemons_clear_ambient_cache_credentials(self) -> None:
        for service in ("seaweedfs", "seaweedfs-open"):
            for key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
                with self.subTest(service=service, key=key):
                    self.assertEqual(self.services[service]["environment"].get(key), "")

    def test_outer_clients_keep_their_cache_credentials(self) -> None:
        for key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
            self.assertNotIn(key, self.client_environment, "clear credentials on the service, never on its clients")


@unittest.skipUnless(boto3 and reachable(), "needs boto3 and the seaweedfs service (OBJECT_STORAGE_ENDPOINT)")
class ObjectStorageTest(unittest.TestCase):
    def test_dev_credentials_write_and_read_the_posthog_bucket(self) -> None:
        client = boto3.client(
            "s3",
            endpoint_url=ENDPOINT,
            aws_access_key_id=os.environ.get("OBJECT_STORAGE_ACCESS_KEY_ID", "object_storage_root_user"),
            aws_secret_access_key=os.environ.get(
                "OBJECT_STORAGE_SECRET_ACCESS_KEY", "object_storage_root_password"
            ),
            region_name="us-east-1",
        )
        key = f"enact-check/{uuid.uuid4()}"
        client.put_object(Bucket="posthog", Key=key, Body=b"ok")
        try:
            self.assertEqual(client.get_object(Bucket="posthog", Key=key)["Body"].read(), b"ok")
        finally:
            client.delete_object(Bucket="posthog", Key=key)

    def test_a_test_may_create_its_own_bucket(self) -> None:
        client = boto3.client(
            "s3",
            endpoint_url=ENDPOINT,
            aws_access_key_id=os.environ.get("OBJECT_STORAGE_ACCESS_KEY_ID", "object_storage_root_user"),
            aws_secret_access_key=os.environ.get(
                "OBJECT_STORAGE_SECRET_ACCESS_KEY", "object_storage_root_password"
            ),
            region_name="us-east-1",
        )
        bucket = f"enact-check-{uuid.uuid4().hex[:12]}"
        client.create_bucket(Bucket=bucket)
        client.delete_bucket(Bucket=bucket)


if __name__ == "__main__":
    unittest.main()
