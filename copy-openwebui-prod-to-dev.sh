#!/usr/bin/env bash
# Copy production OpenWebUI data into the dev volume. Run from the dev checkout.
set -Eeuo pipefail

DEV_DIR="/home/george/pyffeine-dev"
PROD_DIR="/home/george/n8n-compose"
DEV_PROJECT="pyffeine-dev"
PROD_PROJECT="pyffeine-prod"
VOLUME_KEY="openwebui_data"
HELPER_IMAGE="busybox:1.36"
REPLACE=false
PROD_NEEDS_RESTART=false
DEV_NEEDS_RESTART=false

usage() {
  echo "Usage: $0 [--replace]" >&2
  echo "  Default: refuse to copy into a non-empty dev volume." >&2
  echo "  --replace: back up existing dev data, then replace it." >&2
}

for arg in "$@"; do
  case "$arg" in
    --replace)
      [[ "$REPLACE" == false ]] || { usage; exit 2; }
      REPLACE=true
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

compose() {
  local directory="$1" project="$2"
  shift 2
  docker compose --project-name "$project" --env-file "$directory/.env" \
    --file "$directory/docker-compose.yml" "$@"
}

volume_name() {
  local directory="$1" project="$2"
  compose "$directory" "$project" config --format json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"]["openwebui_data"]["name"])'
}

container_id() {
  compose "$1" "$2" ps --all --quiet openwebui | head -n 1
}

container_running() {
  local id="$1"
  [[ -n "$id" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]
}

restore_service_states() {
  local failed=false
  set +e
  if [[ "$DEV_NEEDS_RESTART" == true ]]; then
    echo "==> Restarting development OpenWebUI"
    compose "$DEV_DIR" "$DEV_PROJECT" start openwebui || failed=true
  fi
  if [[ "$PROD_NEEDS_RESTART" == true ]]; then
    echo "==> Restarting production OpenWebUI"
    compose "$PROD_DIR" "$PROD_PROJECT" start openwebui || failed=true
  fi
  if [[ "$failed" == true ]]; then
    echo "ERROR: A previously running OpenWebUI service could not be restarted; inspect its Compose logs." >&2
    return 1
  fi
}
trap restore_service_states EXIT

[[ "$(pwd -P)" == "$DEV_DIR" ]] || fail "Run from $DEV_DIR (current directory: $(pwd -P))."
[[ -f "$DEV_DIR/docker-compose.yml" && -f "$DEV_DIR/.env" ]] || fail "Development compose file or .env is missing."
[[ -f "$PROD_DIR/docker-compose.yml" && -f "$PROD_DIR/.env" ]] || fail "Production compose file or .env is missing at $PROD_DIR."
command -v docker >/dev/null 2>&1 || fail "docker is not installed."
command -v python3 >/dev/null 2>&1 || fail "python3 is required to resolve volume names."
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable or permission was denied."

echo "==> Validating Compose configurations"
compose "$PROD_DIR" "$PROD_PROJECT" config >/dev/null
compose "$DEV_DIR" "$DEV_PROJECT" config >/dev/null
PROD_VOLUME="$(volume_name "$PROD_DIR" "$PROD_PROJECT")"
DEV_VOLUME="$(volume_name "$DEV_DIR" "$DEV_PROJECT")"
[[ -n "$PROD_VOLUME" && -n "$DEV_VOLUME" ]] || fail "Could not resolve OpenWebUI volume names."
[[ "$PROD_VOLUME" != "$DEV_VOLUME" ]] || fail "Both environments resolve to '$PROD_VOLUME'; refusing to copy."
docker volume inspect "$PROD_VOLUME" >/dev/null 2>&1 || fail "Production volume '$PROD_VOLUME' does not exist."

# The dev volume is declared external, so Compose does not create it.
if ! docker volume inspect "$DEV_VOLUME" >/dev/null 2>&1; then
  echo "==> Creating empty development volume $DEV_VOLUME"
  docker volume create "$DEV_VOLUME" >/dev/null
fi

PROD_CONTAINER="$(container_id "$PROD_DIR" "$PROD_PROJECT")"
if [[ -n "$PROD_CONTAINER" ]]; then
  PROD_ATTACHED_VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$PROD_CONTAINER")"
  [[ "$PROD_ATTACHED_VOLUME" == "$PROD_VOLUME" ]] || fail "Production container uses '$PROD_ATTACHED_VOLUME' at /data, but Compose resolves '$PROD_VOLUME'. Refusing to copy from a possibly stale configuration."
  if container_running "$PROD_CONTAINER"; then
    PROD_NEEDS_RESTART=true
  fi
fi

# Do not copy while any unexpected container is using the source volume.
for active_container in $(docker ps --quiet --filter "volume=$PROD_VOLUME"); do
  [[ -n "$PROD_CONTAINER" && "$active_container" == "${PROD_CONTAINER:0:12}" ]] ||
    fail "Unexpected running container '$active_container' is using production volume '$PROD_VOLUME'. Stop it before copying."
done

DEV_CONTAINER="$(container_id "$DEV_DIR" "$DEV_PROJECT")"
if [[ -n "$DEV_CONTAINER" ]] && container_running "$DEV_CONTAINER"; then
  DEV_NEEDS_RESTART=true
  DEV_ATTACHED_VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$DEV_CONTAINER")"
  [[ "$DEV_ATTACHED_VOLUME" == "$DEV_VOLUME" ]] || fail "Running dev container uses '$DEV_ATTACHED_VOLUME' at /data, but Compose resolves '$DEV_VOLUME'. Refusing to modify a possibly different volume."
fi

# Pull before checking/copying, and especially before the production outage window.
docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull "$HELPER_IMAGE"

if [[ "$REPLACE" == false ]]; then
  DEV_EMPTY="$(docker run --rm -v "$DEV_VOLUME:/data:ro" "$HELPER_IMAGE" sh -c 'test -z "$(ls -A /data)" && echo yes || echo no')"
  [[ "$DEV_EMPTY" == yes ]] || fail "Development volume '$DEV_VOLUME' is not empty. Use --replace to back it up and replace it."
fi

BACKUP_DIR="$DEV_DIR/backups"
if [[ "$REPLACE" == true ]]; then
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/openwebui-dev-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  [[ ! -e "$BACKUP_FILE" ]] || fail "Backup archive already exists: $BACKUP_FILE"
else
  BACKUP_FILE=""
fi

if [[ "$PROD_NEEDS_RESTART" == true ]]; then
  echo "==> Stopping production OpenWebUI for a consistent copy"
  compose "$PROD_DIR" "$PROD_PROJECT" stop --timeout 30 openwebui
else
  echo "==> Production OpenWebUI is already stopped or absent; using the existing volume without starting it"
fi

[[ -z "$(docker ps --quiet --filter "volume=$PROD_VOLUME")" ]] || fail "Production volume '$PROD_VOLUME' is still in use by a running container."

if [[ "$DEV_NEEDS_RESTART" == true ]]; then
  echo "==> Stopping development OpenWebUI"
  compose "$DEV_DIR" "$DEV_PROJECT" stop --timeout 30 openwebui
fi

# Recheck after stopping dev to avoid racing with application writes.
DEV_EMPTY="$(docker run --rm -v "$DEV_VOLUME:/data:ro" "$HELPER_IMAGE" sh -c 'test -z "$(ls -A /data)" && echo yes || echo no')"
if [[ "$DEV_EMPTY" != yes && "$REPLACE" == false ]]; then
  fail "Development volume '$DEV_VOLUME' is not empty. Use --replace to back it up and replace it."
fi

if [[ "$REPLACE" == true && "$DEV_EMPTY" != yes ]]; then
  echo "==> Backing up existing development data to $BACKUP_FILE"
  docker run --rm -v "$DEV_VOLUME:/data:ro" -v "$BACKUP_DIR:/backup" "$HELPER_IMAGE" \
    sh -ec 'archive="/backup/$(basename "$1")"; tar -czpf "$archive" -C /data .; tar -tzf "$archive" >/dev/null' sh "$BACKUP_FILE"
fi

echo "==> Copying $PROD_VOLUME into $DEV_VOLUME"
if [[ "$DEV_EMPTY" == yes ]]; then
  docker run --rm -v "$PROD_VOLUME:/source:ro" -v "$DEV_VOLUME:/target" "$HELPER_IMAGE" \
    sh -ec 'set -o pipefail; tar -cpf - -C /source . | tar -xpf - -C /target'
else
  docker run --rm -v "$PROD_VOLUME:/source:ro" -v "$DEV_VOLUME:/target" "$HELPER_IMAGE" \
    sh -ec 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf {} +; set -o pipefail; tar -cpf - -C /source . | tar -xpf - -C /target'
fi

echo "==> Volume copy completed. Services that were running will be restarted on exit."
