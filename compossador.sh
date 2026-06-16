#!/bin/sh
set -eu

INTERVAL="${DISCOVERY_INTERVAL:-30}"
INCLUDE_SERVICES="${INCLUDE_SERVICES:-}"
EXCLUDE_SERVICES="${EXCLUDE_SERVICES:-}"
ROUTE_DIR="/tmp/compossador-routes"

log() {
  echo "[compossador] $*"
}

docker_api() {
  curl -fsS --unix-socket /var/run/docker.sock "http://docker$1"
}

self_id() {
  hostname
}

self_json() {
  docker_api "/containers/$(self_id)/json"
}

safe_key() {
  echo "$1_$2_$3" | tr -c 'A-Za-z0-9_.-' '_'
}

service_in_list() {
  list="$1"
  service="$2"

  [ -n "$list" ] || return 1
  printf '%s' "$list" | tr ', ' '\n\n' | grep -Fxq "$service"
}

should_route_service() {
  service="$1"

  if [ -n "$INCLUDE_SERVICES" ] && ! service_in_list "$INCLUDE_SERVICES" "$service"; then
    return 1
  fi

  if service_in_list "$EXCLUDE_SERVICES" "$service"; then
    return 1
  fi

  return 0
}

start_route() {
  listen_port="$1"
  service="$2"
  target_port="$3"

  key="$(safe_key "$listen_port" "$service" "$target_port")"
  pidfile="$ROUTE_DIR/$key.pid"

  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return
    fi
    rm -f "$pidfile"
  fi

  log "server:$listen_port -> $service:$target_port"

  socat \
    "TCP-LISTEN:$listen_port,bind=0.0.0.0,fork,reuseaddr" \
    "TCP:$service:$target_port" &

  echo "$!" > "$pidfile"
}

stop_stale_routes() {
  active_file="$1"

  for pidfile in "$ROUTE_DIR"/*.pid; do
    [ -e "$pidfile" ] || continue

    key="$(basename "$pidfile" .pid)"
    if grep -qx "$key" "$active_file"; then
      continue
    fi

    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "stopping stale route $key"
      kill "$pid" 2>/dev/null || true
    fi

    rm -f "$pidfile"
  done
}

mkdir -p "$ROUTE_DIR"

SELF_JSON="$(self_json)"
PROJECT="$(echo "$SELF_JSON" | jq -r '.Config.Labels["com.docker.compose.project"] // empty')"
SELF_SERVICE="$(echo "$SELF_JSON" | jq -r '.Config.Labels["com.docker.compose.service"] // empty')"

if [ -z "$PROJECT" ]; then
  log "Could not detect Compose project"
  exit 1
fi

log "project: $PROJECT"
log "self service: $SELF_SERVICE"
log "discovery interval: ${INTERVAL}s"
[ -z "$INCLUDE_SERVICES" ] || log "include services: $INCLUDE_SERVICES"
[ -z "$EXCLUDE_SERVICES" ] || log "exclude services: $EXCLUDE_SERVICES"

while true; do
  routes_file="$(mktemp)"
  active_file="$(mktemp)"

  if docker_api "/containers/json" |
    jq -r \
      --arg project "$PROJECT" \
      --arg self "$SELF_SERVICE" '
        .[]
        | select(.Labels["com.docker.compose.project"] == $project)
        | select(.Labels["com.docker.compose.service"] != $self)
        | select(.State == "running")
        | .Labels["com.docker.compose.service"] as $service
        | .Ports[]?
        | select(.Type == "tcp")
        | select(.PublicPort != null)
        | "\(.PublicPort) \($service) \(.PrivatePort)"
      ' > "$routes_file"
  then
    while read -r listen_port service target_port; do
      [ -n "$listen_port" ] || continue
      should_route_service "$service" || continue
      key="$(safe_key "$listen_port" "$service" "$target_port")"
      echo "$key" >> "$active_file"
      start_route "$listen_port" "$service" "$target_port"
    done < "$routes_file"

    stop_stale_routes "$active_file"
  else
    log "Docker discovery failed"
  fi

  rm -f "$routes_file" "$active_file"
  sleep "$INTERVAL"
done
