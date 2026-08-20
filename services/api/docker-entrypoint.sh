#!/usr/bin/env bash
set -euo pipefail

cd /opt/recodex-core

ENVSUBST_VARS='$API_ADDRESS $WEBAPP_ADDRESS $JWT_SECRET $TOKEN_COOKIE_PREFIX $BROKER_ADDRESS $BROKER_AUTH_USER $BROKER_AUTH_PASSWORD $MONITOR_ADDRESS $WORKER_FILES_AUTH_USER $WORKER_FILES_AUTH_PASSWORD $LOCAL_REGISTRATION_ENABLED $MAIL_FROM $ADMIN_EMAIL $DB_HOST $DB_USER $DB_PASSWORD $DB_NAME $SMTP_HOST $SMTP_CLIENT_HOST $SMTP_PORT $SMTP_USER $SMTP_PASSWORD $SMTP_SECURE'
envsubst "$ENVSUBST_VARS" < app/config/config.local.neon.template > app/config/config.local.neon

echo "Waiting for database at ${DB_HOST}..."
until mysqladmin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" --silent 2>/dev/null; do
    sleep 2
done
echo "Database is reachable."

rm -rf temp/cache/* temp/proxies/* 2>/dev/null || true

case "${1:-serve}" in
    serve)
        # Fresh database: build the schema straight from the current entity
        # mappings and mark the whole (144-migration, back to 2017) history as
        # applied, rather than replaying it. A clean replay hits several
        # migrations that are incompatible with modern MariaDB/doctrine-dbal
        # (removed getName() API, DDL implicitly committing under a
        # transactional migration, MariaDB refusing certain FK-column ALTERs
        # even with FOREIGN_KEY_CHECKS=0) -- all things that only affected
        # people upgrading an existing 2017-era install, which a Docker-based
        # fresh install never is.
        TABLE_EXISTS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -N -s \
            -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='doctrine_migrations';")
        if [ "$TABLE_EXISTS" = "0" ]; then
            echo "Fresh database detected: creating schema from current entity mappings..."
            php bin/console orm:schema-tool:create
            php bin/console migrations:sync-metadata-storage
            php bin/console migrations:version --add --all --no-interaction
        else
            php bin/console migrations:migrate --no-interaction
        fi

        if [ "${RECODEX_SEED_DB:-false}" = "true" ] && [ ! -f storage/.seeded ]; then
            # 'init' loads fixtures/init/ -- admin account + hardware group.
            # Deliberately not loading fixtures/base/ (bare RuntimeEnvironment
            # rows with no pipelines attached -- unusable for grading, and
            # includes languages like Java/Mono/FreePascal the worker image
            # doesn't even have toolchains for) or 'demo' (seeds a whole fake
            # course with exercises/submissions). Real runtime environments
            # -- WITH working pipelines -- come from the runtimes:import
            # packages below instead, matching what's actually installed in
            # the worker image (see services/worker/Dockerfile).
            echo "Seeding initial data (db:fill init)..."
            php bin/console db:fill init

            echo "Importing runtime environments + pipelines..."
            for pkg in /opt/recodex-runtimes/*.zip; do
                php bin/console runtimes:import --yes "$pkg"
            done

            touch storage/.seeded
        fi

        # The console commands above just ran as root (this container has no
        # USER directive), so anything they wrote under temp/ -- notably
        # Nette's compiled DI container cache -- is now root-owned. php-fpm's
        # workers run as www-data and need to write there too (cache
        # invalidation, lock files), so hand it back before serving traffic.
        chown -R www-data:www-data temp log storage

        php-fpm -D
        exec nginx -g "daemon off;"
        ;;
    async-worker)
        exec php bin/async-worker
        ;;
    *)
        exec "$@"
        ;;
esac
