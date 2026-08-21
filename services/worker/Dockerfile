# ReCodEx worker (C++): pulls jobs from the broker and executes untrusted submitted
# code inside the `isolate` sandbox (setuid-root, needs cgroups -> run privileged).
# Build context MUST be the repository root (see docker-compose.yaml).

FROM debian:12-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake pkg-config \
        libboost-all-dev libzmq3-dev libyaml-cpp-dev libcurl4-openssl-dev libarchive-dev libcap-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Python 3.13 ---
# Debian 12's own `python3` package is only 3.11, but students commonly write
# and test against whatever GitHub Classroom/their own machine gives them
# (3.12/3.13), which includes syntax bookworm's interpreter flat-out rejects
# (e.g. PEP 701 same-quote-char nested f-strings). `python:3.13-slim` is built
# on Debian *13* (trixie) -- copying its binaries into a bookworm image risks a
# glibc mismatch, so build from source against bookworm's own toolchain/libc
# instead (skipping --enable-optimizations: that's a 30+ minute PGO build for
# a speedup that doesn't matter for grading short student submissions).
WORKDIR /src/python
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget zlib1g-dev libssl-dev libffi-dev libbz2-dev libreadline-dev \
        libsqlite3-dev libncurses-dev libgdbm-dev liblzma-dev uuid-dev \
    && rm -rf /var/lib/apt/lists/* \
    && wget -q https://www.python.org/ftp/python/3.13.1/Python-3.13.1.tgz \
    && tar xf Python-3.13.1.tgz \
    && cd Python-3.13.1 \
    && ./configure --prefix=/usr/local >/dev/null \
    && make -j"$(nproc)" >/dev/null \
    && make altinstall DESTDIR=/staging-python

# --- isolate sandbox ---
# isolate's Makefile bakes DESTDIR into config.o's compiled-in default config
# path (-DCONFIG_FILE), not just into the install destination -- `make install
# DESTDIR=/staging` alone produces a binary that looks for its config at
# /staging/usr/local/etc/isolate forever, since Make doesn't recompile config.o
# on a second invocation with different flags (same prerequisites, so it's
# considered up to date). Build first with NO DESTDIR (bakes in the real
# /usr/local/etc/isolate path this will actually have at runtime), then
# install into the staging dir as a separate step -- the already-built binary
# is reused as-is, only its *install location* changes.
WORKDIR /src/isolate
COPY repos/isolate/. .
RUN make isolate isolate-check-environment && make install DESTDIR=/staging

# --- recodex-worker + judges ---
WORKDIR /src/worker
COPY repos/worker/. .
RUN mkdir build && cd build \
    && cmake -DDISABLE_TESTS=true .. \
    && make -j"$(nproc)" \
    && make install DESTDIR=/staging

FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libzmq5 libyaml-cpp-dev libcurl4 libarchive13 \
        libboost-system-dev libboost-program-options-dev libcap2 \
        ca-certificates gettext-base \
        # runtime libs for the from-source Python 3.13 build below
        libssl3 libffi8 libsqlite3-0 libbz2-1.0 libreadline8 \
        libncurses6 libgdbm6 liblzma5 libuuid1 \
        # --- language toolchains available to submitted jobs: extend as needed ---
        gcc g++ \
        # Java: the java-2024-12-15 runtime package's pipelines invoke plain `javac` and
        # `java`, nothing version-specific, so Debian 12's default JDK (OpenJDK 17) is what
        # they need -- no vendor repo involved.
        default-jdk \
        # needed to fetch the .NET SDK below
        wget \
    && rm -rf /var/lib/apt/lists/*

# .NET 8 for the `cs-dotnet-core` runtime, installed to /opt/dotnet.
#
# **The version is not free to choose.** The runtime package's own
# `Program.runtimeconfig.json` (shipped inside cs-dotnet-core-2024-12-15.zip, which the api
# image imports) pins `"tfm": "netcoreapp8.0"` / `"version": "8.0.0"` with no `rollForward`
# key -- so the host's default roll-forward policy (Minor) will start on 8.0.x but will NOT
# cross to .NET 9 or 10. Installing "the latest .NET" therefore produces a worker that looks
# correctly provisioned and fails every C# submission at run time. (The package's *description*
# text still says "currently v6"; the config in the same zip is the thing that's actually
# loaded, and it says 8.)
#
# The layout below is likewise dictated by the pipeline, not a preference: it compiles with
# Roslyn's csc.dll through the `dotnet` CLI and documents that it needs `/opt/dotnet` plus
# relative symlinks named `latest` under `sdk/` and `shared/Microsoft.NETCore.App/`.
# dotnet-install.sh is used rather than packages.microsoft.com because it drops a
# self-contained tree at a path we choose, which is exactly what those symlinks expect.
ARG DOTNET_CHANNEL=8.0
RUN wget -qO /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir /opt/dotnet \
    && rm /tmp/dotnet-install.sh \
    && ln -s /opt/dotnet/dotnet /usr/bin/dotnet \
    && ln -s "$(basename "$(ls -d /opt/dotnet/sdk/*/ | head -1)")" /opt/dotnet/sdk/latest \
    && ln -s "$(basename "$(ls -d /opt/dotnet/shared/Microsoft.NETCore.App/*/ | head -1)")" \
        /opt/dotnet/shared/Microsoft.NETCore.App/latest \
    && dotnet --info

# (not /staging/lib -- that's just the systemd unit file, irrelevant in Docker,
# and colliding with Debian's merged-/usr symlink for /lib would break the copy)
COPY --from=builder /staging/usr /usr
COPY --from=builder /staging/etc /etc
COPY --from=builder /staging/var /var

# make python3.13 (see builder stage) the `python3`; /usr/local/bin precedes
# /usr/bin on Debian's default PATH, so this takes priority without touching
# anything under /usr itself.
COPY --from=builder /staging-python/usr/local /usr/local
RUN ln -sf /usr/local/bin/python3.13 /usr/local/bin/python3 \
    && ln -sf /usr/local/bin/pip3.13 /usr/local/bin/pip3 \
    # pytest plugins not packaged for Debian go through pip. --break-system-packages
    # is required since this Python build is PEP-668-managed; there's no separate
    # venv here since submitted jobs run as this same interpreter.
    && pip3 install --no-cache-dir --break-system-packages pytest pytest-console-scripts

RUN mkdir -p /var/recodex-worker-wd /var/recodex-worker-cache /var/log/recodex

COPY services/worker/config.yml.template /etc/recodex/worker/config.yml.template
COPY services/worker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# NOTE: this container must run as root (isolate is setuid-root and manipulates
# cgroups/namespaces directly) and with `privileged: true` + host cgroup v1 mount,
# see docker-compose.yaml. This is intentional: the worker is the one component in
# this stack that is designed to execute untrusted code.
ENTRYPOINT ["docker-entrypoint.sh"]
