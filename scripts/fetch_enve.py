#!/usr/bin/env python3
# ruff: noqa: T201
"""
scripts/fetch_enve.py: Pure zero-dependency SigV4 downloader to fetch the hermetic
enve binary directly from Cloudflare R2 / S3 binary cache buckets.
"""

import os
import sys
import hmac
import hashlib
import datetime
import urllib.error
import urllib.request


def sync_to_r2(source: str, endpoint: str, bucket: str, key: str, access_key: str, secret_key: str):
    try:
        with open(source, "rb") as f:
            data = f.read()
        host = endpoint.split("://")[-1].split("/")[0]
        path = f"/{bucket}/{key}"
        now = datetime.datetime.now(datetime.UTC)
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = now.strftime("%Y%m%d")
        payload_hash = hashlib.sha256(data).hexdigest()
        canonical_headers = f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
        signed_headers = "host;x-amz-content-sha256;x-amz-date"
        canonical_request = f"PUT\n{path}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
        region = os.environ.get("AWS_REGION") or "auto"
        service = "s3"
        scope = f"{date_stamp}/{region}/{service}/aws4_request"
        req_hash = hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
        string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{req_hash}"

        def sign(k, msg):
            return hmac.new(k, msg.encode("utf-8"), hashlib.sha256).digest()

        k_date = sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
        k_region = sign(k_date, region)
        k_service = sign(k_region, service)
        k_signing = sign(k_service, "aws4_request")
        signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

        auth_header = (
            f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
        )
        url = f"{endpoint}/{bucket}/{key}"
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Host": host,
                "x-amz-date": amz_date,
                "x-amz-content-sha256": payload_hash,
                "Authorization": auth_header,
                "Content-Type": "application/octet-stream",
            },
            method="PUT",
        )
        with urllib.request.urlopen(req):
            print(f"🚀 Synced updated enve binary to R2 cache ({url})")  # noqa: T201
    except Exception as e:
        print(f"Notice: R2 sync skipped: {e}", file=sys.stderr)


def fetch_enve(destination: str):
    access_key = os.environ.get("R2_ACCESS_KEY_ID") or os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("R2_SECRET_ACCESS_KEY") or os.environ.get("AWS_SECRET_ACCESS_KEY")
    endpoint = (
        os.environ.get("R2_ENDPOINT")
        or os.environ.get("AWS_ENDPOINT_URL")
        or "https://847959617b8d3ada9eb84238a37f56ec.r2.cloudflarestorage.com"
    ).rstrip("/")
    bucket = os.environ.get("R2_BUCKET") or os.environ.get("ENVE_CACHE_BUCKET") or "posthog-enve"
    key = os.environ.get("ENVE_BINARY_KEY") or "bin/enve"
    token = os.environ.get("ENVE_TOKEN") or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

    dest_dir = os.path.dirname(os.path.abspath(destination))
    os.makedirs(dest_dir, exist_ok=True)

    # 1. First attempt: download updated enve binary from GitHub releases if token is available
    if token:
        try:
            import subprocess

            print("📥 Fetching latest enve binary from tonky/enve release v0.5.0...", file=sys.stderr)
            res = subprocess.run(
                [
                    "gh",
                    "release",
                    "download",
                    "v0.5.0",
                    "--repo",
                    "tonky/enve",
                    "-p",
                    "enve",
                    "--output",
                    destination,
                    "--clobber",
                ],
                env={**os.environ, "GH_TOKEN": token},
                capture_output=True,
                text=True,
            )
            if res.returncode == 0 and os.path.exists(destination) and os.path.getsize(destination) > 1000000:
                os.chmod(destination, 0o755)
                size_mb = os.path.getsize(destination) / (1024 * 1024)
                print(f"✅ Downloaded updated enve ({size_mb:.2f} MB) successfully to {destination}")
                if access_key and secret_key:
                    sync_to_r2(destination, endpoint, bucket, key, access_key, secret_key)
                return
        except Exception as e:
            print(f"⚠️ Release download fallback error: {e}", file=sys.stderr)

    # 2. Second attempt: download from Cloudflare R2 binary bucket
    if not access_key or not secret_key:
        print("❌ Error: R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY must be set.", file=sys.stderr)
        sys.exit(1)

    url = f"{endpoint}/{bucket}/{key}"
    host = endpoint.split("://")[-1].split("/")[0]
    path = f"/{bucket}/{key}"

    now = datetime.datetime.now(datetime.UTC)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")

    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_headers = f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = f"GET\n{path}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"

    region = os.environ.get("AWS_REGION") or "auto"
    service = "s3"
    scope = f"{date_stamp}/{region}/{service}/aws4_request"
    req_hash = hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{req_hash}"

    def sign(k, msg):
        return hmac.new(k, msg.encode("utf-8"), hashlib.sha256).digest()

    k_date = sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    k_region = sign(k_date, region)
    k_service = sign(k_region, service)
    k_signing = sign(k_service, "aws4_request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    auth_header = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
    )

    req = urllib.request.Request(
        url,
        headers={
            "Host": host,
            "x-amz-date": amz_date,
            "x-amz-content-sha256": payload_hash,
            "Authorization": auth_header,
        },
        method="GET",
    )

    print(f"📥 Fetching hermetic enve binary from {url} -> {destination}...")

    try:
        with urllib.request.urlopen(req) as resp, open(destination, "wb") as f:
            f.write(resp.read())
    except urllib.error.HTTPError as e:
        print(f"❌ HTTP Error {e.code}: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"❌ Failed to download enve: {e}", file=sys.stderr)
        sys.exit(1)

    os.chmod(destination, 0o755)
    size_mb = os.path.getsize(destination) / (1024 * 1024)
    print(f"✅ Downloaded enve ({size_mb:.2f} MB) successfully to {destination}")


if __name__ == "__main__":
    dest = sys.argv[1] if len(sys.argv) > 1 else "/usr/local/bin/enve"
    fetch_enve(dest)
