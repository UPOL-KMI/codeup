#!/usr/bin/env bash
set -euo pipefail

WORKER_ID="${WORKER_ID:-1}"
CONFIG_PATH="/etc/recodex/worker/config-${WORKER_ID}.yml"

envsubst '$WORKER_ID $BROKER_URI $WORKER_HWGROUP $API_ADDRESS $API_INTERNAL_ADDRESS $WORKER_FILES_AUTH_USER $WORKER_FILES_AUTH_PASSWORD $LOG_LEVEL' \
    < /etc/recodex/worker/config.yml.template > "$CONFIG_PATH"

# --- cgroup delegation for isolate 2.x ---
#
# Isolate 2.x requires cgroup **v2** and expects a subtree of the hierarchy delegated to it, with
# the controllers it needs enabled. On a systemd host that is what the shipped `isolate.service`
# and `isolate.slice` units do; a container has no systemd, so we do it here, and point
# `cg_root` at the result (see the isolate config in this component's Dockerfile).
#
# **In the host's root cgroup, not under the container's own, and that is forced rather than
# chosen.** cgroup v2 forbids a non-root cgroup from holding processes while enabling controllers
# for its children -- the "no internal processes" rule -- and the container's own cgroup holds this
# worker. The root is exempt, which is why this works. It relies on `privileged: true` plus
# `cgroup: host` in docker-compose.yaml; without those, the mount is read-only and this fails.
#
# It has to run on every start, because the subtree does not survive the container.
CG_ROOT=/sys/fs/cgroup/isolate

setup_cgroup() {
    if [ ! -d /sys/fs/cgroup ] || ! grep -qE '^cgroup2? /sys/fs/cgroup cgroup2 ' /proc/mounts; then
        echo "!! /sys/fs/cgroup is not a cgroup v2 mount. isolate 2.x cannot run here." >&2
        echo "   On a cgroup v1 host, use isolate 1.x instead -- see COMPATIBILITY.md." >&2
        return 1
    fi

    mkdir -p "$CG_ROOT" || {
        echo "!! cannot create $CG_ROOT -- is the container privileged with cgroup: host?" >&2
        return 1
    }

    # Requested one at a time: a single write is rejected outright if any one controller is
    # unavailable, which would hide which of them is missing.
    for controller in memory cpu cpuset; do
        if ! grep -qw "$controller" "$CG_ROOT/cgroup.controllers"; then
            echo "!! controller '$controller' is not delegated to $CG_ROOT." >&2
            echo "   Available: $(cat "$CG_ROOT/cgroup.controllers")" >&2
            return 1
        fi
        echo "+$controller" > "$CG_ROOT/cgroup.subtree_control" 2>/dev/null || true
    done

    local enabled
    enabled="$(cat "$CG_ROOT/cgroup.subtree_control")"
    for controller in memory cpu cpuset; do
        grep -qw "$controller" <<< "$enabled" || {
            echo "!! could not enable '$controller' for isolate's sandboxes (have: $enabled)" >&2
            return 1
        }
    done

    mkdir -p /run/isolate/locks
    echo "== cgroup v2 subtree ready at $CG_ROOT (controllers: $enabled) =="
}

# Fail the container rather than starting a worker that would turn every submission into an
# internal error. A worker that cannot sandbox is worse than a worker that is visibly down: the
# first reports rubbish verdicts to students, the second gets noticed.
setup_cgroup

echo "== isolate environment check =="
/usr/local/bin/isolate-check-environment || true

exec recodex-worker -c "$CONFIG_PATH"
