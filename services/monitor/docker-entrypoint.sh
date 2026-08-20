#!/usr/bin/env bash
set -euo pipefail

envsubst '$LOG_LEVEL' \
    < /etc/recodex/monitor/config.yml.template > /etc/recodex/monitor/config.yml

exec recodex-monitor -c /etc/recodex/monitor/config.yml
