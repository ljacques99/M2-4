# ── Dockerfile del OMS ────────────────────────────────────────────
# Multi-stage. Cumple la spec del Vídeo 1:
#   ✓ usuario no-root (UID > 10000)
#   ✓ HEALTHCHECK contra /healthz
#   ✓ Labels OCI con trazabilidad
#   ✓ Tamaño minimizado (slim runtime)
#   ✓ Cero secretos en capas
#
# Estamos asumiendo Node.js como ejemplo. Si el OMS está en Python o Java,
# adapta las imágenes base pero MANTÉN la estructura multi-stage.

# syntax=docker/dockerfile:1.6

# ─── Etapa 1: builder ─────────────────────────────────────────────
FROM node:22-alpine AS deps
WORKDIR /app

# Aprovechar cache: solo invalidar pip install si requirements cambia
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ─── Etapa 2: runtime ─────────────────────────────────────────────
FROM node:22-alpine
WORKDIR /app

# Usuario no-root con UID alto
RUN addgroup -g 10001 oms && \
    adduser  -u 10001 -G oms -s /bin/false -D oms

# Copiar solo los node_modules de la etapa anterior (sin compilador)
COPY --from=deps /app/node_modules ./node_modules

# Copiar el código de la app
COPY . .

USER oms

ENV NODE_ENV=production \
    PORT=8080

EXPOSE 8080

# Healthcheck para Cloud Run (también lo usa el HTTPS LB en su health check)
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

# TODO(alumno): añade más labels OCI si quieres (created, vendor, title, description)
LABEL org.opencontainers.image.source="https://github.com/TODO-org/oms" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.revision="TODO_GIT_SHA" \
      org.opencontainers.image.licenses="MIT"

CMD ["node", "server.js"]
