# --- Build stage -----------------------------------------------------------
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json tsconfig.json ./
RUN npm ci
COPY src ./src
RUN npm run build

# --- Runtime stage ---------------------------------------------------------
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production

COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --from=builder /app/dist ./dist

# Persistent storage for tokens.json and the APNs `.p8` key. Mounted via
# docker-compose so they survive container rebuilds.
RUN mkdir -p /app/data

EXPOSE 8787
CMD ["node", "dist/index.js"]
