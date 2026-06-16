# Compossador

Compossador is a small Docker Compose sidecar that exposes a stable in-stack hostname for services that publish ports.

It is intended for Compose stacks where containers need to call the same ports that are published on the host, but without leaving the Docker network. For example, if a service publishes `127.0.0.1:3131:3000`, another container can call `server:3131` and Compossador forwards that connection to `service-name:3000`.

## How It Works

Compossador runs inside the same Compose project as the services it routes to.

It:

- discovers its own Compose project from Docker's Compose labels
- lists running containers in that project
- reads Docker port metadata for published TCP ports
- starts one `socat` TCP listener for each discovered mapping
- forwards `server:<published-port>` to `<compose-service>:<container-port>`
- polls periodically for service additions, removals, recreation, and port changes

It does not require labels on application services.

## Example

```yaml
services:
  compossador:
    image: ghcr.io/dan-dr/compossador:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      default:
        aliases:
          - server

  app:
    image: hashicorp/http-echo
    command: -text="hello" -listen=:3000
    ports:
      - "127.0.0.1:3131:3000"
```

From another service on the same Compose network:

```sh
curl http://server:3131
```

That forwards to:

```text
app:3000
```

## Configuration

| Variable | Default | Description |
|---|---:|---|
| `DISCOVERY_INTERVAL` | `30` | Polling interval in seconds. |
| `INCLUDE_SERVICES` | empty | Optional allow-list of Compose service names. Comma or space separated. |
| `EXCLUDE_SERVICES` | empty | Optional deny-list of Compose service names. Comma or space separated. Applied after `INCLUDE_SERVICES`. |

Example:

```yaml
environment:
  DISCOVERY_INTERVAL: 30
  INCLUDE_SERVICES: app,api,worker
  EXCLUDE_SERVICES: worker
```

## Notes

- Only TCP published ports are routed.
- `expose:` and Dockerfile `EXPOSE` are ignored because they are not host-published ports.
- The sidecar excludes itself automatically by Compose service label.
- Service names are resolved through Docker's embedded DNS on the Compose network.
- If a service is scaled to multiple containers, Docker DNS behavior determines which backend is used.

## Security

Compossador reads Docker metadata through `/var/run/docker.sock`.

Mounting the Docker socket is sensitive. The `:ro` mount makes the socket path read-only in the filesystem, but it does not make the Docker API read-only. Only run this image in trusted stacks where access to Docker metadata is acceptable.

## Image

```text
ghcr.io/dan-dr/compossador:latest
```

Version tags are published when Git tags beginning with `v` are pushed.
