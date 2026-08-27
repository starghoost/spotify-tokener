#!/usr/bin/env python3
"""Cache seguro y healthchecks para el spotify-tokener oficial."""

from __future__ import annotations

import http.server
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Optional
from urllib.parse import urlsplit


def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default)).strip()
    try:
        value = int(raw)
    except ValueError as error:
        raise SystemExit(f"{name} debe ser un entero; recibido: {raw!r}") from error
    if not minimum <= value <= maximum:
        raise SystemExit(f"{name} debe estar entre {minimum} y {maximum}; recibido: {value}")
    return value


INTERNAL_PORT = env_int("TOKENER_INTERNAL_PORT", 8082, 1, 65535)
PROXY_PORT = env_int("TOKENER_PORT", 8081, 1, 65535)
MAX_CACHE_SECS = env_int("TOKEN_CACHE_SECS", 3300, 60, 21600)
FETCH_TIMEOUT = env_int("TOKEN_FETCH_TIMEOUT", 120, 5, 600)
EXPIRY_SKEW_SECS = env_int("TOKEN_EXPIRY_SKEW_SECS", 120, 15, 1800)
UPSTREAM_URL = f"http://127.0.0.1:{INTERNAL_PORT}/api/token"
MAX_RESPONSE_BYTES = 1024 * 1024


@dataclass(frozen=True)
class CacheSnapshot:
    data: Optional[bytes]
    expires_at: float
    last_success_at: Optional[int]
    consecutive_failures: int

    @property
    def remaining_seconds(self) -> int:
        return max(0, int(self.expires_at - time.monotonic()))

    @property
    def valid(self) -> bool:
        return self.data is not None and self.remaining_seconds > 0


class TokenState:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._data: Optional[bytes] = None
        self._expires_at = 0.0
        self._last_success_at: Optional[int] = None
        self._consecutive_failures = 0

    def snapshot(self) -> CacheSnapshot:
        with self._lock:
            return CacheSnapshot(
                data=self._data,
                expires_at=self._expires_at,
                last_success_at=self._last_success_at,
                consecutive_failures=self._consecutive_failures,
            )

    def record_success(self, data: bytes, ttl_seconds: int) -> None:
        with self._lock:
            self._data = data
            self._expires_at = time.monotonic() + ttl_seconds
            self._last_success_at = int(time.time())
            self._consecutive_failures = 0

    def record_failure(self) -> None:
        with self._lock:
            self._consecutive_failures += 1


STATE = TokenState()
REFRESH_LOCK = threading.Lock()
STOP_EVENT = threading.Event()


def compute_ttl(payload: dict) -> int:
    access_token = payload.get("accessToken")
    if not isinstance(access_token, str) or not access_token.strip():
        raise ValueError("Spotify devolvio una respuesta sin accessToken")

    expires_at_ms = payload.get("accessTokenExpirationTimestampMs")
    if expires_at_ms is None:
        return MAX_CACHE_SECS

    try:
        remaining = (int(expires_at_ms) - int(time.time() * 1000)) // 1000
    except (TypeError, ValueError) as error:
        raise ValueError("Spotify devolvio una expiracion invalida") from error

    ttl = min(MAX_CACHE_SECS, remaining - EXPIRY_SKEW_SECS)
    if ttl < 30:
        raise ValueError("Spotify devolvio un token vencido o demasiado proximo a vencer")
    return ttl


def fetch_upstream(cookie_header: Optional[str] = None) -> tuple[bytes, int]:
    headers = {
        "Accept": "application/json",
        "User-Agent": "OdysseySpotifyTokener/1.0",
    }
    if cookie_header:
        headers["Cookie"] = cookie_header

    request = urllib.request.Request(UPSTREAM_URL, headers=headers, method="GET")
    with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT) as response:
        data = response.read(MAX_RESPONSE_BYTES + 1)
        if len(data) > MAX_RESPONSE_BYTES:
            raise ValueError("La respuesta upstream supera 1 MiB")

    payload = json.loads(data.decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("La respuesta upstream no es un objeto JSON")
    return data, compute_ttl(payload)


def refresh_cache(*, force: bool, blocking: bool) -> bool:
    acquired = REFRESH_LOCK.acquire(blocking=blocking)
    if not acquired:
        return False

    try:
        if not force and STATE.snapshot().valid:
            return True
        print(f"[proxy] Solicitando token anonimo a {UPSTREAM_URL}...", flush=True)
        data, ttl_seconds = fetch_upstream()
        STATE.record_success(data, ttl_seconds)
        print(f"[proxy] Token anonimo listo; TTL efectivo={ttl_seconds}s.", flush=True)
        return True
    except (OSError, ValueError, json.JSONDecodeError, urllib.error.URLError) as error:
        STATE.record_failure()
        print(f"[proxy] No fue posible renovar el token: {type(error).__name__}: {error}", flush=True)
        return False
    finally:
        REFRESH_LOCK.release()


def schedule_refresh(*, force: bool) -> None:
    def runner() -> None:
        refresh_cache(force=force, blocking=False)

    threading.Thread(target=runner, name="token-refresh", daemon=True).start()


def refresh_loop() -> None:
    while not STOP_EVENT.wait(30):
        snapshot = STATE.snapshot()
        refresh_ahead = max(60, EXPIRY_SKEW_SECS)
        if not snapshot.valid:
            schedule_refresh(force=False)
        elif snapshot.remaining_seconds <= refresh_ahead:
            schedule_refresh(force=True)


class TokenHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 128

    def handle_error(self, request: object, client_address: object) -> None:
        error = sys.exc_info()[1]
        # Wings/Docker pueden comprobar el puerto con una conexion TCP que se
        # cierra sin enviar HTTP. Es una sonda valida, no un fallo del servicio.
        if isinstance(error, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


class TokenHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "OdysseySpotifyTokener"
    sys_version = ""

    def send_bytes(self, status: int, data: bytes, content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def send_json(self, status: int, payload: dict) -> None:
        self.send_bytes(status, json.dumps(payload, separators=(",", ":")).encode("utf-8"))

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        path = urlsplit(self.path).path

        if path == "/livez":
            self.send_json(200, {"alive": True})
            return

        if path in {"/healthz", "/readyz"}:
            snapshot = STATE.snapshot()
            status = 200 if snapshot.valid else 503
            self.send_json(status, {
                "healthy": snapshot.valid,
                "cacheReady": snapshot.data is not None,
                "cacheExpiresInSeconds": snapshot.remaining_seconds,
                "lastSuccessAt": snapshot.last_success_at,
                "consecutiveFailures": snapshot.consecutive_failures,
            })
            return

        if path != "/api/token":
            self.send_json(404, {"error": "not_found"})
            return

        cookie_header = self.headers.get("Cookie")
        if cookie_header:
            try:
                data, _ = fetch_upstream(cookie_header)
                self.send_bytes(200, data)
            except (OSError, ValueError, json.JSONDecodeError, urllib.error.URLError) as error:
                print(f"[proxy] Fallo al solicitar token con cookies: {type(error).__name__}", flush=True)
                self.send_json(503, {"error": "account_token_unavailable"})
            return

        snapshot = STATE.snapshot()
        if not snapshot.valid:
            refresh_cache(force=False, blocking=True)
            snapshot = STATE.snapshot()

        if not snapshot.valid or snapshot.data is None:
            self.send_json(503, {"error": "anonymous_token_unavailable"})
            return

        if snapshot.remaining_seconds <= max(60, EXPIRY_SKEW_SECS):
            schedule_refresh(force=True)
        self.send_bytes(200, snapshot.data)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def main() -> None:
    print(f"[proxy] Iniciando en 0.0.0.0:{PROXY_PORT}; upstream={UPSTREAM_URL}", flush=True)
    schedule_refresh(force=False)
    threading.Thread(target=refresh_loop, name="refresh-scheduler", daemon=True).start()

    server = TokenHTTPServer(("0.0.0.0", PROXY_PORT), TokenHandler)

    def stop_handler(_signum: int, _frame: object) -> None:
        STOP_EVENT.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        STOP_EVENT.set()
        server.server_close()
        print("[proxy] Servidor detenido.", flush=True)


if __name__ == "__main__":
    main()
