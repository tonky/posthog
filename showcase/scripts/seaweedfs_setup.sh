#!/usr/bin/env bash
# The object storage's identities and buckets, as docker-compose.base.yml's objectstorage
# bootstrap registers them: the dev credentials (OBJECT_STORAGE_ACCESS_KEY_ID) as an admin, an
# anonymous identity for unsigned clients, and the buckets the code writes to. Without them
# every signed request is refused (AccessDenied; data-warehouse tests, exports, recordings).
# `weed shell` exits 0 whenever the master answers, so this checks the persisted state.
set -uo pipefail
# The master's port slots (enve.cue), as this postStart hook sees them: `host:port.grpcPort`, since
# `weed shell` otherwise dials the master's port + 10000, which a named instance's free ports aren't.
master="127.0.0.1:${PORT_MASTER:?the master port slot}.${PORT_MASTER_GRPC:?the master gRPC port slot}"
key="${OBJECT_STORAGE_ACCESS_KEY_ID:-object_storage_root_user}"
secret="${OBJECT_STORAGE_SECRET_ACCESS_KEY:-object_storage_root_password}"
buckets=(posthog ducklake-dev ai-blobs)

for _ in $(seq 60); do
    {
        echo "s3.configure -access_key=$key -secret_key=$secret -user=posthog -actions=Admin -apply"
        echo "s3.configure -user=anonymous -actions=Admin -apply"
        for bucket in "${buckets[@]}"; do echo "s3.bucket.create -name $bucket"; done
    } | weed shell -master="$master" >/dev/null 2>&1
    listed=$(echo s3.bucket.list | weed shell -master="$master" 2>/dev/null)
    identities=$(echo s3.configure | weed shell -master="$master" 2>/dev/null)
    ready=1
    for bucket in "${buckets[@]}"; do
        [[ "$listed" == *"$bucket"* ]] || ready=0
    done
    [[ "$identities" == *"$key"* && "$identities" == *anonymous* ]] || ready=0
    [ "$ready" = 1 ] && exit 0
    sleep 1
done
echo "SeaweedFS has no ${buckets[*]} buckets or $key identity after 60 attempts" >&2
exit 1
