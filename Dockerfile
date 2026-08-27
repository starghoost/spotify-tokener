# syntax=docker/dockerfile:1.7

ARG GO_VERSION=1.24
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS builder

# Fijado para que una reconstruccion futura no compile codigo upstream distinto.
ARG SPOTIFY_TOKENER_REF=e15e48eb142a70d196932fa902363b191492e384
ARG TARGETOS
ARG TARGETARCH

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    mkdir -p /out \
    && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
       go install "github.com/topi314/spotify-tokener@${SPOTIFY_TOKENER_REF}" \
    && find /go/bin -type f -name spotify-tokener \
       -exec cp {} /out/spotify-tokener \; \
    && test -x /out/spotify-tokener

FROM debian:bookworm-slim

ARG SPOTIFY_TOKENER_REF=e15e48eb142a70d196932fa902363b191492e384
ARG BUILD_REVISION=unknown

LABEL org.opencontainers.image.title="Odyssey Spotify Tokener" \
      org.opencontainers.image.description="Hardened spotify-tokener runtime for LavaSrc and Pterodactyl" \
      org.opencontainers.image.source="https://github.com/starghoost/spotify-tokener" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      io.odyssey.spotify-tokener.upstream-revision="${SPOTIFY_TOKENER_REF}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        chromium \
        curl \
        dumb-init \
        fonts-liberation \
        python3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --home-dir /home/container --uid 1000 container

WORKDIR /home/container

ENV HOME=/home/container \
    USER=container \
    SPOTIFY_TOKENER_CHROME_PATH=/usr/local/bin/chrome-no-sandbox \
    SPOTIFY_TOKENER_LOG_LEVEL=INFO \
    TOKENER_INTERNAL_PORT=8082 \
    TOKENER_PORT=8081 \
    TOKEN_CACHE_SECS=3300 \
    TOKEN_EXPIRY_SKEW_SECS=120 \
    TOKEN_FETCH_TIMEOUT=120 \
    TOKEN_STARTUP_GRACE_SECS=180 \
    TOKEN_UNHEALTHY_AFTER_FAILURES=3

COPY --from=builder /out/spotify-tokener /usr/local/bin/spotify-tokener
COPY --chmod=755 docker/chrome-no-sandbox /usr/local/bin/chrome-no-sandbox
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 docker/token-proxy.py /usr/local/bin/token-proxy.py

USER container

EXPOSE 8081
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${TOKENER_PORT}/healthz" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/local/bin/spotify-tokener"]
