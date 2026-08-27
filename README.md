# Odyssey Spotify Tokener

Imagen mantenida para entregar a LavaSrc tokens anonimos de Spotify sin exponer
Chromium directamente. Esta variante esta preparada para Docker y Pterodactyl.

## Arquitectura

El contenedor ejecuta tres capas:

1. `spotify-tokener`, compilado desde un commit fijo del proyecto oficial;
2. Chromium, aislado detras de un wrapper compatible con contenedores;
3. `token-proxy.py`, que valida la respuesta, respeta su expiracion, renueva en
   segundo plano y ofrece healthchecks sin revelar el token.

El binario upstream escucha solo en `127.0.0.1:8082`. El proxy escucha en el
puerto externo. En Pterodactyl utiliza automaticamente `SERVER_PORT`; en Docker
normal utiliza `TOKENER_PORT` y su valor predeterminado es `8081`.

## Imagen

```text
ghcr.io/starghoost/spotify-tokener:latest
```

Cada compilacion tambien publica una etiqueta inmutable `sha-<12 caracteres>`.
La imagen contiene SBOM y provenance generados por BuildKit, se publica para
`linux/amd64` y `linux/arm64`, y se reconstruye semanalmente para recibir parches
del sistema y Chromium. El codigo upstream permanece fijado en el argumento
`SPOTIFY_TOKENER_REF`; actualizarlo requiere una revision explicita.

## Pterodactyl

Importa [pterodactyl/egg-spotify-tokener.json](pterodactyl/egg-spotify-tokener.json)
y crea un servidor con una asignacion principal. Para conservar la configuracion
actual de Odyssey, asigna `192.168.1.28:8081`.

El Egg no fuerza valores dentro del comando de inicio. Las variables del panel
se inyectan normalmente y el proxy toma el puerto de la asignacion principal.
Pterodactyl marca el servicio listo solo cuando aparece:

```text
SPOTIFY_TOKEN_PROXY_READY port=8081
```

Si el paquete GHCR es privado, Wings necesita credenciales para descargarlo. La
opcion mas sencilla para esta imagen sin secretos es publicar el paquete GHCR;
el repositorio de codigo puede continuar privado.

## Docker independiente

```bash
docker run -d \
  --name spotify-tokener \
  --restart unless-stopped \
  -p 192.168.1.28:8081:8081 \
  ghcr.io/starghoost/spotify-tokener:latest
```

No publiques este puerto en Internet. El endpoint devuelve un token utilizable;
limitalo a la LAN, una red privada de contenedores o reglas de firewall.

## Endpoints

| Endpoint | Funcion | Puede incluir token |
| --- | --- | --- |
| `/api/token` | Respuesta compatible con LavaSrc | Si |
| `/healthz` | Estado de cache y renovacion | No |
| `/readyz` | Preparacion para recibir trafico | No |
| `/livez` | Vida del proceso HTTP | No |

Comprueba salud sin imprimir credenciales:

```bash
curl -fsS http://192.168.1.28:8081/healthz
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  http://192.168.1.28:8081/api/token
```

## Configuracion para LavaSrc y Odyssey

En el `application.yml` de Lavalink:

```yaml
plugins:
  lavasrc:
    spotify:
      customTokenEndpoint: "http://192.168.1.28:8081/api/token"
```

En el `.env` privado de Odyssey:

```dotenv
SPOTIFY_TOKEN_ENDPOINT=http://192.168.1.28:8081/api/token
```

Ambas capas deben apuntar al mismo servicio. No guardes el contenido devuelto
por `/api/token` en Git ni lo pegues en logs.

## Variables operativas

| Variable | Predeterminado | Proposito |
| --- | ---: | --- |
| `SPOTIFY_TOKENER_LOG_LEVEL` | `INFO` | Nivel del binario upstream |
| `TOKENER_INTERNAL_PORT` | `8082` | Puerto loopback interno |
| `TOKENER_PORT` | `8081` | Puerto del proxy fuera de Pterodactyl |
| `TOKEN_CACHE_SECS` | `3300` | Limite maximo de cache |
| `TOKEN_EXPIRY_SKEW_SECS` | `120` | Margen antes de expiracion |
| `TOKEN_FETCH_TIMEOUT` | `120` | Timeout de Chromium |
| `TOKEN_STARTUP_GRACE_SECS` | `180` | Ventana para el primer token |
| `TOKEN_UNHEALTHY_AFTER_FAILURES` | `3` | Fallos antes del reinicio |

La expiracion entregada por Spotify prevalece sobre `TOKEN_CACHE_SECS`. Las
peticiones que contienen cookies no comparten la cache anonima: se reenvian al
upstream de forma individual para no mezclar sesiones.

## Recuperacion automatica

- El proxy renueva antes del vencimiento y evita tormentas de solicitudes con
  un unico bloqueo de renovacion.
- El supervisor comprueba ambos procesos y la validez del token.
- Si Chromium, el binario o el proxy mueren, el contenedor finaliza con error;
  Docker o Wings lo reinician conforme a su politica.
- `dumb-init` reenvia señales y recoge procesos hijos durante apagados normales.

## Diagnostico

```bash
docker logs --tail 100 spotify-tokener
docker inspect --format '{{json .State.Health}}' spotify-tokener
```

Un `503` en `/readyz` durante el arranque es normal. Si supera la ventana de
arranque, revisa salida HTTPS, DNS, memoria disponible y el estado de Chromium.
