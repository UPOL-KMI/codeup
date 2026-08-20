#!/usr/bin/env bash
set -euo pipefail

envsubst '$API_ADDRESS $NOTIFIER_PORT $BROKER_AUTH_USER $BROKER_AUTH_PASSWORD $MONITOR_HOST $MONITOR_ZMQ_PORT $LOG_LEVEL' \
    < /etc/recodex/broker/config.yml.template > /etc/recodex/broker/config.yml

exec recodex-broker -c /etc/recodex/broker/config.yml
