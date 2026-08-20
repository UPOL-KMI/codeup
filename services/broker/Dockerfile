# ReCodEx broker (C++): schedules jobs between core-api and workers over ZeroMQ.
# Build context MUST be the repository root (see docker-compose.yaml).

FROM debian:12-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake pkg-config \
        libzmq3-dev libyaml-cpp-dev libcurl4-openssl-dev \
        libboost-system-dev libboost-filesystem-dev libboost-program-options-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY repos/broker/. .
RUN mkdir build && cd build \
    && cmake -DDISABLE_TESTS=true .. \
    && make -j"$(nproc)"

FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libzmq5 libyaml-cpp-dev libcurl4 \
        libboost-system-dev libboost-filesystem-dev libboost-program-options-dev \
        ca-certificates gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /var/lib/recodex --shell /usr/sbin/nologin recodex \
    && mkdir -p /etc/recodex/broker /var/log/recodex \
    && chown recodex:recodex /etc/recodex/broker /var/log/recodex

COPY --from=builder /src/build/recodex-broker /usr/bin/recodex-broker
COPY services/broker/config.yml.template /etc/recodex/broker/config.yml.template
COPY services/broker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER recodex
EXPOSE 9657 9658
ENTRYPOINT ["docker-entrypoint.sh"]
