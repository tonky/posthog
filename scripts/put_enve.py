#!/usr/bin/env python3
"""
scripts/put_enve.py: Pure zero-dependency SigV4 uploader to upload hermetic
enve binary directly to Cloudflare R2 / S3 binary cache buckets.
"""
import datetime
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.request


def put_enve(source: str, key: str = "bin/enve") -> bool:
    if not os.path.isfile(source):
        print(f"❌ Error: Source file {source} does not exist.", file=sys.stderr)
        return False

    access_key = os.environ.get("R2_ACCESS_KEY_ID") or os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("R2_SECRET_ACCESS_KEY") or os.environ.get("AWS_SECRET_ACCESS_KEY")
    endpoint = (
        os.environ.get("R2_ENDPOINT")
        or os.environ.get("AWS_ENDPOINT_URL")
        or "https://847959617b8d3ada9eb84238a37f56ec.r2.cloudflarestorage.com"
    ).rstrip("/")
    bucket = os.environ.get("R2_BUCKET") or os.environ.get("ENVE_CACHE_BUCKET") or "posthog-enve"

    if not access_key or not secret_key:
        print("❌ Error: R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY must be set.", file=sys.stderr)
        return False

    with open(source, "rb") as f:
        data = f.read()

    url = f"{endpoint}/{bucket}/{key}"
    host = endpoint.split("://")[-1].split("/")[0]
    path = f"/{bucket}/{key}"

    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")

    payload_hash = hashlib.sha256(data).hexdigest()
    canonical_headers = (
        f"content-length:{len(data)}\n"
        f"content-type:application/octet-stream\n"
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "content-length;content-type;host;x-amz-content-sha256;x-amz-date"
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
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Host": host,
            "Content-Length": str(len(data)),
            "Content-Type": "application/octet-stream",
            "x-amz-date": amz_date,
            "x-amz-content-sha256": payload_hash,
            "Authorization": auth_header,
        },
        method="PUT",
    )

    size_mb = len(data) / (1024 * 1024)
    print(f"📤 Uploading {source} ({size_mb:.2f} MB) -> {url}...")
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"✅ Upload succeeded! HTTP Status: {resp.status}")
            return True
    except urllib.error.HTTPError as e:
        print(f"❌ Upload HTTP Error {e.code}: {e.reason}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"❌ Upload failed: {e}", file=sys.stderr)
        return False


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "/home/tonky/.cargo/bin/enve"
    target_key = sys.argv[2] if len(sys.argv) > 2 else (os.environ.get("ENVE_BINARY_KEY") or "bin/enve")
    success = put_enve(src, target_key)
    if not success:
        sys.exit(1)
