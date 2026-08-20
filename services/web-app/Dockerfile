# ReCodEx web-app: React SPA server-rendered by a bundled Node/Express app.
# `yarn build` + `yarn deploy` produces a self-contained ./prod dir (bin/, views/, public/,
# etc/env.json) — the server bundle has no runtime node_modules dependency, so the final
# image only needs a plain Node runtime, not the whole yarn toolchain.
# Build context MUST be the repository root (see docker-compose.yaml).

FROM node:22-bookworm-slim AS builder
WORKDIR /src
RUN corepack enable
COPY repos/web-app/package.json repos/web-app/yarn.lock repos/web-app/.yarnrc.yml ./
COPY repos/web-app/.yarn ./.yarn
RUN yarn install --immutable
COPY repos/web-app/. .
# Compatibility patches against current master -- see the comments in
# services/web-app/patch-compatibility.js for what each one fixes and why.
COPY services/web-app/patch-compatibility.js ./patch-compatibility.js
RUN node patch-compatibility.js && rm patch-compatibility.js
RUN printf 'NODE_ENV=production\nVERSION=docker\n' > .env \
    && yarn build \
    && yarn deploy

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /opt/recodex-web --shell /usr/sbin/nologin recodex
WORKDIR /opt/recodex-web
COPY --from=builder --chown=recodex:recodex /src/prod ./
COPY services/web-app/env.json.template ./etc/env.json.template
COPY services/web-app/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV NODE_ENV=production
USER recodex
EXPOSE 8080
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "bin/server.mjs"]
