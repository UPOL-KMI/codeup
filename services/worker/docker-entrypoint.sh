#!/usr/bin/env bash
set -euo pipefail

WORKER_ID="${WORKER_ID:-1}"
CONFIG_PATH="/etc/recodex/worker/config-${WORKER_ID}.yml"

envsubst '$WORKER_ID $BROKER_URI $WORKER_HWGROUP $API_ADDRESS $WORKER_FILES_AUTH_USER $WORKER_FILES_AUTH_PASSWORD $LOG_LEVEL' \
    < /etc/recodex/worker/config.yml.template > "$CONFIG_PATH"

echo "== isolate environment check (informational; failures here mean the host's" \
     "cgroup setup is not compatible with isolate 1.8 -- see README) =="
/usr/local/bin/isolate-check-environment || true

exec recodex-worker -c "$CONFIG_PATH"
