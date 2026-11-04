# shellcheck shell=bash
# Sourced by every wrapper in this directory. The wrapper's file name is the base name of the binary it starts, so
# every wrapper is the same two lines. Each version directory carries its own copy of this file, because a deployed
# version must not depend on files outside it.

# ClickHouse starts a wrapper with copies of its open files, including client connections. A connection stays open
# while any copy of it is open, so a long-running UDF process keeps a connection open after the server closes it,
# and the next request on that connection never gets a response. Close every inherited descriptor except stdin,
# stdout and stderr before anything else. The wrappers run under bash because sh cannot close a descriptor above 9.
# /dev/fd lists this shell's descriptors on Linux (a link to /proc/self/fd) and macOS alike, and `exec N>&-` through
# eval runs on macOS's bash 3.2, which has no `{fd}` redirections.
for fd_path in /dev/fd/*; do
    fd=${fd_path##*/}
    if (( fd > 2 )); then
        eval "exec $fd>&-"
    fi
done

DIR_NAME=$(dirname "$0")
UDF_NAME=$(basename "$0")

TEMP_DIR=$(mktemp -d -p /tmp "${UDF_NAME}_XXXXXXXXXX")
trap 'rm -rf "$TEMP_DIR"; exit' 0

# The committed binaries are Linux ones. A ClickHouse running natively on macOS starts a host build instead, which is
# never committed (.gitignore): clickhouse-udfs/util's `go build` and funnel-udf's `cargo build --release`, saved as
# <name>_darwin_<arch>.
case $(uname -s)-$(uname -m) in
Darwin-*)
    EXECUTABLE_NAME="${UDF_NAME}_darwin_$(uname -m)"
    ;;
*-aarch64)
    EXECUTABLE_NAME="${UDF_NAME}_aarch64"
    ;;
*)
    EXECUTABLE_NAME="${UDF_NAME}_x86_64"
    ;;
esac
if [ ! -f "$DIR_NAME/$EXECUTABLE_NAME" ]; then
    echo "$UDF_NAME: no $EXECUTABLE_NAME in $DIR_NAME for this host" >&2
    exit 1
fi

# A deploy replaces the binaries in user_scripts while pooled processes still run them. Each process runs a private
# copy, so the replacement never touches a file a process is executing.
cp "$DIR_NAME/$EXECUTABLE_NAME" "$TEMP_DIR/$EXECUTABLE_NAME"
chmod +x "$TEMP_DIR/$EXECUTABLE_NAME"
"$TEMP_DIR/$EXECUTABLE_NAME" "$@"
