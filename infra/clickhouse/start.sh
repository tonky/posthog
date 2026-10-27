#!/usr/bin/env bash
# The clickhouse service's command (enve.cue), in the checkout with the instance's $DATA_DIR:
# renders config.xml's @DATA_DIR@ and @ROOT@ (a named instance's data dir lies deeper than
# .enve/data), lays this platform's profile overrides over upstream's users, and starts the
# server. Platform choices live here, not in enve.cue's command.
set -euo pipefail
data=${DATA_DIR:?DATA_DIR is the instance data dir enve gives a service}
root=$PWD
sed -e "s|@DATA_DIR@|$data|g" -e "s|@ROOT@|$root|g" "$data/config.template.xml" > "$data/config.xml"
# Upstream's users and profiles (docker/clickhouse/users-dev.xml, which compose mounts as
# users.xml), through a link in the data dir: ClickHouse merges the users.d/ beside a users
# file over it, so overrides go to the data dir and the checkout stays upstream's.
ln -sfn "$root/docker/clickhouse/users-dev.xml" "$data/users.xml"
rm -rf "$data/users.d"
mkdir -p "$data/users.d"
platform=$(uname -s | tr '[:upper:]' '[:lower:]')
if [ -f "infra/clickhouse/users.d/$platform.xml" ]; then
    cp "infra/clickhouse/users.d/$platform.xml" "$data/users.d/"
fi
exec clickhouse-server --config-file="$data/config.xml"
