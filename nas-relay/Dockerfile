# --- Build stage -----------------------------------------------------------
FROM docker.m.daocloud.io/library/node:20-alpine AS builder
WORKDIR /app
RUN npm config set registry https://registry.npmmirror.com \
 && npm config set fetch-retries 5 \
 && npm config set fetch-retry-mintimeout 20000 \
 && npm config set fetch-retry-maxtimeout 120000 \
 && npm config set network-timeout 120000 \
 && npm config set audit false \
 && npm config set fund false
COPY package*.json tsconfig.json ./
RUN npm ci --include=dev --no-audit --no-fund
COPY src ./src
RUN npm run build

# --- Runtime stage ---------------------------------------------------------
FROM docker.m.daocloud.io/library/node:20-alpine
WORKDIR /app
ENV NODE_ENV=production

RUN npm config set registry https://registry.npmmirror.com \
 && npm config set fetch-retries 5 \
 && npm config set fetch-retry-mintimeout 20000 \
 && npm config set fetch-retry-maxtimeout 120000 \
 && npm config set network-timeout 120000 \
 && npm config set audit false \
 && npm config set fund false
COPY package*.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY --from=builder /app/dist ./dist

# Persistent storage for tokens.json and the APNs `.p8` key. Mounted via
# docker-compose so they survive container rebuilds.
RUN mkdir -p /app/data

EXPOSE 8787
CMD ["node", "dist/index.js"]
