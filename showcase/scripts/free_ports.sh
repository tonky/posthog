#!/usr/bin/env bash
# Reserves a block of consecutive TCP ports host-wide for a server set a test starts itself
# and prints its first port (run_personhog_gate.sh: the personhog stack the test harness
# spawns, which listens at fixed offsets from one base).
#
#   base="$(PORTS_OWNER=$$ showcase/scripts/free_ports.sh <count>)"
#   PORTS_OWNER=$$ showcase/scripts/free_ports.sh --release <base> <count>
#
# A fixed or slot-derived port collides: two checkouts' runs on one host (two agents'
# gates, or the Mac and a VM: OrbStack forwards a VM's listeners to the Mac's 127.0.0.1)
# take the same one. So every port of the block is
#   - outside the kernel's ephemeral range (Linux 32768+, macOS 49152+), where outgoing
#     connections take theirs, and below enve's instance ports (20000-32767);
#   - reserved for its owner's life: a directory per port under FREE_PORTS_DIR holds the
#     owner's pid (PORTS_OWNER, else the caller). A port a live owner holds is skipped, a
#     dead owner's taken over. The directory and protocol are forgejo's helpers/free-ports.sh
#     and odoo's helpers/free-port.sh, so no two usecases' runs on one host share a port;
#   - free when picked: nothing accepts a connection on it.
# Linux and macOS take halves of the range; FREE_PORTS_RANGE (`low-high`) narrows it.
set -euo pipefail

owner="${PORTS_OWNER:-${PPID}}"
dir="${FREE_PORTS_DIR:-/tmp/test-ports-$(id -u)}"
if [[ -n "${FREE_PORTS_RANGE:-}" ]]; then
    low="${FREE_PORTS_RANGE%-*}" high="${FREE_PORTS_RANGE#*-}"
elif [[ "$(uname -s)" == Linux ]]; then
    low=10000 high=14999
else
    low=15000 high=19999
fi
mkdir -p "${dir}"

# Drops the owner's reservations of ports $1..$2-1 (another owner's stay).
release() {
    local port
    for ((port = $1; port < $2; port++)); do
        [[ "$(cat "${dir}/${port}/owner" 2>/dev/null || true)" == "${owner}" ]] || continue
        rm -rf "${dir:?}/${port}"
    done
}

if [[ "${1:-}" == --release ]]; then
    release "$2" $(($2 + $3))
    exit 0
fi
count="${1:?usage: free_ports.sh <count> | --release <base> <count>}"

# Takes the port's reservation for the owner; a reservation whose owner is gone is stale.
reserve() {
    local lock="${dir}/$1" pid
    if mkdir "${lock}" 2>/dev/null; then
        echo "${owner}" > "${lock}/owner"
        return 0
    fi
    pid="$(cat "${lock}/owner" 2>/dev/null || true)"
    # A reservation being written has no pid yet: it's taken. The owner's own is too.
    [[ -n "${pid}" && "${pid}" != "${owner}" ]] || return 1
    ! kill -0 "${pid}" 2>/dev/null || return 1
    echo "${owner}" > "${lock}/owner"
}
# Nothing accepts a connection on the port.
unused() {
    ! (exec 3<> "/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Blocks aligned to the range's start, the first at random, then every block in turn.
blocks=$(((high - low + 1) / count))
[[ ${blocks} -gt 0 ]] || { echo "free_ports: ${low}-${high} holds no ${count} ports" >&2; exit 1; }
first=$(((RANDOM * 32768 + RANDOM) % blocks))
for ((i = 0; i < blocks; i++)); do
    base=$((low + ((first + i) % blocks) * count))
    taken=${base}
    for ((port = base; port < base + count; port++)); do
        reserve "${port}" || break
        taken=$((port + 1))
        unused "${port}" || break
    done
    if [[ ${port} -eq $((base + count)) ]]; then
        echo "${base}"
        exit 0
    fi
    # This block's reservations go, a listening port's too; a live owner's stays theirs.
    release "${base}" "${taken}"
done
echo "free_ports: no ${count} free ports in a row in ${low}-${high} (${dir})" >&2
exit 1
