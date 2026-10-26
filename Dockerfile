# syntax=docker/dockerfile:1
#
# Production images for the backend. One Dockerfile, two targets:
#
#   docker build --target api    -t podcast-ai-api .
#   docker build --target worker -t podcast-ai-worker .
#
# The api image also carries scripts/ and infrastructure/migrations, so one-off
# tasks run in it: `node scripts/migrate.mjs`, `node scripts/create-user.mjs ...`.
# Both images run as the unprivileged `node` user (uid 1000) with NODE_ENV=production.
# infrastructure/docker-compose.prod.yml builds and runs them.

ARG NODE_IMAGE=node:20-bookworm-slim

FROM ${NODE_IMAGE} AS base
WORKDIR /app
ENV npm_config_update_notifier=false \
    npm_config_fund=false \
    npm_config_audit=false

# Workspace manifests only, so dependency layers stay cached until they change.
FROM base AS manifests
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/
COPY apps/worker/package.json apps/worker/
COPY packages/shared-types/package.json packages/shared-types/

# --- Build: all dependencies (TypeScript etc.), compile every workspace ------
FROM manifests AS build
RUN --mount=type=cache,target=/root/.npm npm ci
COPY tsconfig.base.json ./
COPY packages/shared-types packages/shared-types
COPY apps/api apps/api
COPY apps/worker apps/worker
RUN npm run build

# --- Production dependencies per service --------------------------------------
FROM manifests AS api-deps
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --workspace @podcast/api

FROM manifests AS worker-deps
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --workspace @podcast/worker

# --- Common runtime base ----------------------------------------------------------
FROM base AS runtime
ENV NODE_ENV=production
# Mount point of the shared audio volume. A new named volume takes over this
# ownership, so the unprivileged user can write to it.
RUN mkdir -p /data/audio && chown node:node /data/audio
# Application files stay owned by root: the runtime user can read, not modify them.
COPY package.json ./
COPY packages/shared-types/package.json packages/shared-types/
COPY --from=build /app/packages/shared-types/dist packages/shared-types/dist

# --- API (also used for migrations and admin scripts) -----------------------------
FROM runtime AS api
COPY --from=api-deps /app/node_modules node_modules
COPY apps/api/package.json apps/api/
COPY --from=build /app/apps/api/dist apps/api/dist
COPY scripts scripts
COPY infrastructure/migrations infrastructure/migrations
USER node
EXPOSE 4000
CMD ["node", "apps/api/dist/index.js"]

# --- Worker (needs ffmpeg/ffprobe for audio segmentation) -------------------------
FROM runtime AS worker
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*
COPY --from=worker-deps /app/node_modules node_modules
COPY apps/worker/package.json apps/worker/
COPY --from=build /app/apps/worker/dist apps/worker/dist
USER node
CMD ["node", "apps/worker/dist/index.js"]
