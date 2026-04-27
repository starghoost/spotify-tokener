FROM golang:1.24-bookworm AS builder
RUN go install github.com/topi314/spotify-tokener@master

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dumb-init \
    python3 \
    chromium \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libc6 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libgbm1 \
    libgcc-s1 \
    libglib2.0-0 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libstdc++6 \
    libx11-6 \
    libx11-xcb1 \
    libxcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxshmfence1 \
    libxss1 \
    libxtst6 \
    xdg-utils \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -d /home/container container

WORKDIR /home/container
ENV USER=container HOME=/home/container

COPY --from=builder /go/bin/spotify-tokener /usr/local/bin/spotify-tokener

RUN cat > /usr/local/bin/chrome-no-sandbox <<'CHROMESCRIPT' && chmod +x /usr/local/bin/chrome-no-sandbox
#!/bin/sh
set -eu
for candidate in /usr/bin/chromium /usr/bin/chromium-browser; do
  if [ -x "$candidate" ]; then
    exec "$candidate" \
      --no-sandbox \
      --disable-setuid-sandbox \
      --disable-dev-shm-usage \
      "$@"
  fi
done
echo "ERROR: Chromium no encontrado." >&2
exit 127
CHROMESCRIPT

RUN cat > /usr/local/bin/token-proxy.py <<'PYEOF' && chmod +x /usr/local/bin/token-proxy.py
#!/usr/bin/env python3
import http.server
import json
import os
import threading
import time
import urllib.request

TOKENER_PORT = int(os.environ.get("TOKENER_INTERNAL_PORT", "8082"))
PROXY_PORT = int(os.environ.get("TOKENER_PORT", "8081"))
CACHE_SECS = int(os.environ.get("TOKEN_CACHE_SECS", "3300"))
FETCH_TIMEOUT = int(os.environ.get("TOKEN_FETCH_TIMEOUT", "120"))
EXPIRY_SKEW_SECS = int(os.environ.get("TOKEN_EXPIRY_SKEW_SECS", "60"))
UNHEALTHY_AFTER_FAILURES = int(os.environ.get("TOKEN_UNHEALTHY_AFTER_FAILURES", "3"))

_cache_data = None
_cache_expires = 0.0
_cache_lock = threading.Lock()
_fetch_lock = threading.Lock()
_last_success_at = 0.0
_consecutive_failures = 0

def _compute_cache_ttl_seconds(payload):
    expires_at_ms = int(payload.get("accessTokenExpirationTimestampMs") or 0)
    if expires_at_ms <= 0:
        return max(30, CACHE_SECS)

    remaining_secs = max(0, (expires_at_ms - int(time.time() * 1000)) / 1000)
    ttl_secs = max(0, remaining_secs - EXPIRY_SKEW_SECS)
    return max(0, min(CACHE_SECS, int(ttl_secs)))

def _fetch():
    global _cache_data, _cache_expires, _last_success_at, _consecutive_failures
    url = f"http://127.0.0.1:{TOKENER_PORT}/api/token"
    print(f"[proxy] Obteniendo token de {url}...", flush=True)
    try:
        with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT) as resp:
            data = resp.read()
        payload = json.loads(data.decode("utf-8"))
        ttl_secs = _compute_cache_ttl_seconds(payload)
        with _cache_lock:
            _cache_data = data
            _cache_expires = time.monotonic() + ttl_secs
            _last_success_at = time.monotonic()
            _consecutive_failures = 0
        print(f"[proxy] Token cacheado OK. TTL efectivo {ttl_secs}s.", flush=True)
        return True
    except Exception as e:
        with _cache_lock:
            _consecutive_failures += 1
        print(f"[proxy] Error obteniendo token: {e}", flush=True)
        return False

def ensure_background_refresh():
    def runner():
        with _fetch_lock:
            _fetch()
    t = threading.Thread(target=runner, daemon=True)
    t.start()

def background_refresh_loop():
    while True:
        with _cache_lock:
            expires = _cache_expires
            has_cache = _cache_data is not None
        if not has_cache:
            time.sleep(15)
            ensure_background_refresh()
            continue
        sleep_secs = max(expires - time.monotonic() - 60, 30)
        time.sleep(sleep_secs)
        print("[proxy] Renovando token en background...", flush=True)
        with _fetch_lock:
            _fetch()

class TokenHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            with _cache_lock:
                expired = time.monotonic() >= _cache_expires
                has_cache = _cache_data is not None
                failures = _consecutive_failures
            healthy = has_cache and (not expired or failures < UNHEALTHY_AFTER_FAILURES)
            self.send_response(200 if healthy else 503)
            self.send_header("Content-Type", "application/json")
            body = json.dumps({
                "healthy": healthy,
                "hasCache": has_cache,
                "expired": expired,
                "consecutiveFailures": failures
            }).encode("utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        if self.path != "/api/token":
            self.send_response(404)
            self.end_headers()
            return

        with _cache_lock:
            data = _cache_data
            expired = time.monotonic() >= _cache_expires

        if data is None:
            ensure_background_refresh()
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            body = json.dumps({"error": "token_not_ready"}).encode("utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        if expired:
            with _fetch_lock:
                _fetch()
            with _cache_lock:
                data = _cache_data
                expired = time.monotonic() >= _cache_expires
            if data is None or expired:
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                body = json.dumps({"error": "token_expired"}).encode("utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, fmt, *args):
        pass

print(f"[proxy] Iniciando. Tokener en :{TOKENER_PORT}, proxy en :{PROXY_PORT}", flush=True)
ensure_background_refresh()
threading.Thread(target=background_refresh_loop, daemon=True).start()
print(f"[proxy] Proxy listo. Respondiendo en :{PROXY_PORT}", flush=True)
httpd = http.server.ThreadingHTTPServer(("0.0.0.0", PROXY_PORT), TokenHandler)
httpd.serve_forever()
PYEOF

RUN cat > /usr/local/bin/entrypoint.sh <<'ENTRYSH' && chmod +x /usr/local/bin/entrypoint.sh
#!/bin/sh
set -eu

TOKENER_INTERNAL_PORT="${TOKENER_INTERNAL_PORT:-8082}"
TOKENER_PORT="${TOKENER_PORT:-8081}"
TOKEN_STARTUP_GRACE_SECS="${TOKEN_STARTUP_GRACE_SECS:-45}"
export TOKENER_INTERNAL_PORT TOKENER_PORT

echo "[entrypoint] Arrancando tokener en background (puerto interno ${TOKENER_INTERNAL_PORT})..."
"$@" &
TOKENER_PID=$!

echo "[entrypoint] Esperando que el servidor tokener arranque..."
for i in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:${TOKENER_INTERNAL_PORT}/" \
    --max-time 1 --connect-timeout 1 2>/dev/null; then
    echo "[entrypoint] Tokener HTTP activo (intento ${i})."
    break
  fi
  sleep 1
done

echo "[entrypoint] Iniciando proxy de cache..."
/usr/local/bin/token-proxy.py &
PROXY_PID=$!

echo "[entrypoint] Sistema listo. Tokener PID=${TOKENER_PID}, Proxy PID=${PROXY_PID}"

PROXY_HEALTH_FAILS=0
STARTED_AT="$(date +%s)"
while true; do
  if ! kill -0 "$TOKENER_PID" 2>/dev/null; then
    echo "[entrypoint] El tokener terminó. Cerrando contenedor."
    wait "$TOKENER_PID"
    exit 1
  fi
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "[entrypoint] El proxy terminó. Cerrando contenedor."
    wait "$PROXY_PID"
    exit 1
  fi
  if curl -s -o /dev/null "http://127.0.0.1:${TOKENER_INTERNAL_PORT}/" --max-time 5 --connect-timeout 2 2>/dev/null; then
    :
  else
    echo "[entrypoint] El tokener interno dejó de responder. Cerrando contenedor."
    exit 1
  fi

  NOW_TS="$(date +%s)"
  ELAPSED="$((NOW_TS - STARTED_AT))"
  if [ "$ELAPSED" -lt "$TOKEN_STARTUP_GRACE_SECS" ]; then
    sleep 10
    continue
  fi

  if curl -fsS -o /dev/null "http://127.0.0.1:${TOKENER_PORT}/healthz" --max-time 5 --connect-timeout 2 2>/dev/null; then
    PROXY_HEALTH_FAILS=0
  else
    PROXY_HEALTH_FAILS=$((PROXY_HEALTH_FAILS + 1))
    echo "[entrypoint] Healthcheck del proxy/tokener falló (${PROXY_HEALTH_FAILS})."
    if [ "$PROXY_HEALTH_FAILS" -ge 3 ]; then
      echo "[entrypoint] El proxy/tokener quedó inutilizable. Cerrando contenedor para reinicio."
      exit 1
    fi
  fi

  sleep 10
done
ENTRYSH

USER container
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/bin/sh", "-lc", "cd /home/container && exec $STARTUP"]
