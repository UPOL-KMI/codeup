# ReCodEx monitor: relays broker job-progress messages (ZeroMQ) to browsers (WebSocket).
# Build context MUST be the repository root (see docker-compose.yaml).
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /var/lib/recodex --shell /usr/sbin/nologin recodex \
    && mkdir -p /etc/recodex/monitor /var/log/recodex \
    && chown recodex:recodex /etc/recodex/monitor /var/log/recodex

WORKDIR /src
COPY repos/monitor/. .
RUN pip install --no-cache-dir .

COPY services/monitor/config.yml.template /etc/recodex/monitor/config.yml.template
COPY services/monitor/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER recodex
EXPOSE 4567 7894
ENTRYPOINT ["docker-entrypoint.sh"]
