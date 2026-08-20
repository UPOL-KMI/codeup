#!/usr/bin/env bash
set -euo pipefail

cd /opt/recodex-web

envsubst '$WEB_APP_PORT $API_ADDRESS $RECODEX_TITLE $TOKEN_COOKIE_PREFIX $LOCAL_REGISTRATION_ENABLED' \
    < etc/env.json.template > etc/env.json

exec "$@"
