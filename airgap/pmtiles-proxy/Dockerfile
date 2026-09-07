FROM docker.io/library/node:24.20.0-alpine3.24@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

FROM docker.io/library/node:24.20.0-alpine3.24@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf
LABEL org.opencontainers.image.title="overture-pmtiles-proxy-airgap"
WORKDIR /app
# Package managers are build-time tools; remove them from the offline runtime.
RUN apk upgrade --no-cache libcrypto3 libssl3 \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /opt/yarn* \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg /usr/local/bin/corepack
COPY --from=dependencies /app/node_modules ./node_modules
COPY package.json config.mjs s3.mjs server.mjs main.mjs ./
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=7s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/readyz',{signal:AbortSignal.timeout(6000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "main.mjs"]
