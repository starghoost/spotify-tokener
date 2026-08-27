#!/bin/sh
set -eu
umask 077

TOKENER_INTERNAL_PORT="${TOKENER_INTERNAL_PORT:-8082}"
if [ -n "${SERVER_PORT:-}" ]; then
  TOKENER_PORT="$SERVER_PORT"
else
  TOKENER_PORT="${TOKENER_PORT:-8081}"
fi
TOKEN_STARTUP_GRACE_SECS="${TOKEN_STARTUP_GRACE_SECS:-180}"
TOKEN_UNHEALTHY_AFTER_FAILURES="${TOKEN_UNHEALTHY_AFTER_FAILURES:-3}"
SPOTIFY_TOKENER_ADDR="${SPOTIFY_TOKENER_ADDR:-127.0.0.1:${TOKENER_INTERNAL_PORT}}"

validate_uint() {
  value_name="$1"
  value="$2"
  case "$value" in
    ''|*[!0-9]*)
      echo "[entrypoint] $value_name debe ser un entero; recibido: $value" >&2
      exit 64
      ;;
  esac
}

validate_uint TOKENER_INTERNAL_PORT "$TOKENER_INTERNAL_PORT"
validate_uint TOKENER_PORT "$TOKENER_PORT"
validate_uint TOKEN_STARTUP_GRACE_SECS "$TOKEN_STARTUP_GRACE_SECS"
validate_uint TOKEN_UNHEALTHY_AFTER_FAILURES "$TOKEN_UNHEALTHY_AFTER_FAILURES"

export TOKENER_INTERNAL_PORT TOKENER_PORT TOKEN_STARTUP_GRACE_SECS
export TOKEN_UNHEALTHY_AFTER_FAILURES SPOTIFY_TOKENER_ADDR

if [ "$#" -eq 0 ]; then
  echo "[entrypoint] Falta el comando de spotify-tokener." >&2
  exit 64
fi

TOKENER_PID=""
PROXY_PID=""

shutdown() {
  trap - INT TERM
  echo "[entrypoint] Deteniendo servicios..."
  [ -z "$PROXY_PID" ] || kill -TERM "$PROXY_PID" 2>/dev/null || true
  [ -z "$TOKENER_PID" ] || kill -TERM "$TOKENER_PID" 2>/dev/null || true
  [ -z "$PROXY_PID" ] || wait "$PROXY_PID" 2>/dev/null || true
  [ -z "$TOKENER_PID" ] || wait "$TOKENER_PID" 2>/dev/null || true
  exit 0
}

trap shutdown INT TERM

echo "[entrypoint] Arrancando spotify-tokener en ${SPOTIFY_TOKENER_ADDR}..."
"$@" &
TOKENER_PID=$!

echo "[entrypoint] Esperando el HTTP interno..."
internal_ready=0
attempt=1
while [ "$attempt" -le 60 ]; do
  if ! kill -0 "$TOKENER_PID" 2>/dev/null; then
    echo "[entrypoint] spotify-tokener termino durante el arranque." >&2
    wait "$TOKENER_PID" || true
    exit 1
  fi
  if curl -sS -o /dev/null "http://127.0.0.1:${TOKENER_INTERNAL_PORT}/" \
      --max-time 1 --connect-timeout 1 2>/dev/null; then
    internal_ready=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if [ "$internal_ready" -ne 1 ]; then
  echo "[entrypoint] spotify-tokener no abrio el puerto interno a tiempo." >&2
  kill -TERM "$TOKENER_PID" 2>/dev/null || true
  wait "$TOKENER_PID" 2>/dev/null || true
  exit 1
fi

echo "[entrypoint] Iniciando proxy y cache en 0.0.0.0:${TOKENER_PORT}..."
/usr/local/bin/token-proxy.py &
PROXY_PID=$!

started_at="$(date +%s)"
while true; do
  if ! kill -0 "$TOKENER_PID" 2>/dev/null || ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "[entrypoint] Un proceso termino antes de completar el arranque." >&2
    exit 1
  fi
  if curl -fsS -o /dev/null "http://127.0.0.1:${TOKENER_PORT}/readyz" \
      --max-time 5 --connect-timeout 2 2>/dev/null; then
    break
  fi
  now="$(date +%s)"
  if [ $((now - started_at)) -ge "$TOKEN_STARTUP_GRACE_SECS" ]; then
    echo "[entrypoint] No se obtuvo un token valido durante la ventana de arranque." >&2
    exit 1
  fi
  sleep 2
done

echo "SPOTIFY_TOKEN_PROXY_READY port=${TOKENER_PORT}"

health_failures=0
while true; do
  if ! kill -0 "$TOKENER_PID" 2>/dev/null; then
    echo "[entrypoint] spotify-tokener termino; solicitando reinicio." >&2
    wait "$TOKENER_PID" || true
    exit 1
  fi
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "[entrypoint] token-proxy termino; solicitando reinicio." >&2
    wait "$PROXY_PID" || true
    exit 1
  fi

  if curl -fsS -o /dev/null "http://127.0.0.1:${TOKENER_PORT}/healthz" \
      --max-time 5 --connect-timeout 2 2>/dev/null; then
    health_failures=0
  else
    health_failures=$((health_failures + 1))
    echo "[entrypoint] Healthcheck fallo (${health_failures}/${TOKEN_UNHEALTHY_AFTER_FAILURES})."
    if [ "$health_failures" -ge "$TOKEN_UNHEALTHY_AFTER_FAILURES" ]; then
      echo "[entrypoint] Servicio inutilizable; solicitando reinicio limpio." >&2
      exit 1
    fi
  fi
  sleep 10
done
