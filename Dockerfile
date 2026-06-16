FROM alpine:3.20

LABEL org.opencontainers.image.title="Compossador"
LABEL org.opencontainers.image.description="A lightweight Docker Compose port ambassador sidecar"
LABEL org.opencontainers.image.source="https://github.com/dan-dr/compossador"

RUN apk add --no-cache curl jq socat

COPY compossador.sh /usr/local/bin/compossador
RUN chmod +x /usr/local/bin/compossador

ENTRYPOINT ["/usr/local/bin/compossador"]
