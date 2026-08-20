# ReCodEx core-api (PHP/Nette REST API) + nginx, single image.
# Build context MUST be the repository root (see docker-compose.yaml), because
# it needs both repos/api (upstream source) and services/api (our deploy files).
FROM php:8.4-fpm-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx \
        git curl unzip pkg-config gettext-base default-mysql-client ca-certificates \
        build-essential autoconf \
        libyaml-dev libzip-dev libicu-dev libzmq3-dev libonig-dev \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql zip mbstring intl bcmath \
    && pecl install yaml \
    && docker-php-ext-enable yaml \
    && git clone --depth 1 https://github.com/zeromq/php-zmq.git /tmp/php-zmq \
    && cd /tmp/php-zmq && phpize && ./configure && make -j"$(nproc)" && make install \
    && docker-php-ext-enable zmq \
    && cd / && rm -rf /tmp/php-zmq \
    && apt-get purge -y --auto-remove build-essential autoconf git pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Runtime environment + pipeline packages matching the toolchains actually
# installed in the worker image (gcc, g++, python3 -- see
# services/worker/Dockerfile). `db:fill` fixtures only provide bare
# RuntimeEnvironment rows with no pipeline attached (unusable for grading);
# these packages are the real thing, imported at first boot by
# docker-entrypoint.sh. Extend this list in lockstep whenever you add more
# toolchains to the worker image (see https://github.com/ReCodEx/runtimes).
RUN mkdir -p /opt/recodex-runtimes && cd /opt/recodex-runtimes \
    && for pkg in \
        bash-2024-07-22.zip \
        c-gcc-linux-2024-12-15.zip \
        cxx-gcc-linux-2024-12-15.zip \
        python3-2024-12-15.zip \
    ; do curl -fsSLO "https://raw.githubusercontent.com/ReCodEx/runtimes/master/generic/$pkg"; done

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /opt/recodex-core

# composer.json's autoload section classmaps app/Bootstrap.php directly, so
# `composer install` needs the full source tree present -- no separate
# composer.json-only caching layer here.
COPY repos/api/. .
# Compatibility patches against current master -- see the comments in
# services/api/patch-compatibility.php for what each one fixes and why.
COPY services/api/patch-compatibility.php ./patch-compatibility.php
RUN php patch-compatibility.php && rm patch-compatibility.php
RUN composer install --no-dev --no-interaction --no-progress --no-scripts --optimize-autoloader \
    && mkdir -p storage/local storage/hash job_config log temp \
    && chown -R www-data:www-data /opt/recodex-core \
    && chmod -R 775 log temp storage job_config

COPY services/api/nginx-site.conf /etc/nginx/sites-enabled/default
COPY services/api/php-recodex.ini /usr/local/etc/php/conf.d/zz-recodex.ini
COPY services/api/config.local.neon.template app/config/config.local.neon.template
COPY services/api/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && rm -f /etc/nginx/sites-enabled/default.orig

EXPOSE 80
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["serve"]
