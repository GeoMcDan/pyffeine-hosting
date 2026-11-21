#!/usr/bin/env bash
# Extract Open WebUI's uploaded source files from a deployment volume to the host.
set -Eeuo pipefail

INSTANCE="pyffeine"
ENVIRONMENT="live"
ENVIRONMENT_SET=false
INSTANCE_SET=false
HELPER_IMAGE="busybox:1.36"
BACKUP_ROOT="/home/george/openwebui-uploads"
SERVICE_NEEDS_RESTART=false
STAGING_DIR=""

usage() {
  cat <<EOF
Usage: $0 [prod|live|dev] [--instance NAME]

Backs up only Open WebUI's /data/uploads directory. The default environment is
live. Files are extracted under:
  $BACKUP_ROOT/<instance>/<environment>/<volume>/<UTC timestamp>/

The Open WebUI service is stopped during extraction if it was running, then
restarted automatically. This is not a complete Knowledge backup: it does not
include Open WebUI's database or the configured vector-store index.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    prod|live|dev)
      [[ "$ENVIRONMENT_SET" == false ]] || { usage >&2; exit 2; }
      case "$1" in
        prod|live) ENVIRONMENT="live" ;;
        dev) ENVIRONMENT="dev" ;;
      esac
      ENVIRONMENT_SET=true
      shift
      ;;
    --instance)
      (($# >= 2)) || { usage >&2; exit 2; }
      [[ "$INSTANCE_SET" == false ]] || { usage >&2; exit 2; }
      INSTANCE="$2"
      INSTANCE_SET=true
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

valid_path_segment() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

valid_path_segment "$INSTANCE" ||
  fail "Invalid instance name '$INSTANCE'. Use letters, digits, dots, underscores, or hyphens."

case "$ENVIRONMENT" in
  live)
    SOURCE_DIR="/home/george/n8n-compose"
    PROJECT_NAME="pyffeine-prod"
    ;;
  dev)
    SOURCE_DIR="/home/george/pyffeine-dev"
    PROJECT_NAME="pyffeine-dev"
    ;;
esac

compose() {
  docker compose --project-name "$PROJECT_NAME" \
    --env-file "$SOURCE_DIR/.env" \
    --file "$SOURCE_DIR/docker-compose.yml" "$@"
}

restore_service_state() {
  local exit_status=$?
  trap - EXIT
  set +e

  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    if ! rm -rf -- "$STAGING_DIR"; then
      echo "ERROR: Could not remove incomplete backup directory '$STAGING_DIR'." >&2
      exit_status=1
    fi
  fi

  if [[ "$SERVICE_NEEDS_RESTART" == true ]]; then
    echo "==> Restarting the $ENVIRONMENT Open WebUI service"
    if ! compose start openwebui; then
      echo "ERROR: Open WebUI was stopped for backup but could not be restarted." >&2
      exit_status=1
    fi
  fi

  exit "$exit_status"
}
trap restore_service_state EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$SOURCE_DIR/docker-compose.yml" ]] || fail "Compose file not found: $SOURCE_DIR/docker-compose.yml"
[[ -f "$SOURCE_DIR/.env" ]] || fail "Environment file not found: $SOURCE_DIR/.env"
command -v docker >/dev/null 2>&1 || fail "docker is not installed."
command -v python3 >/dev/null 2>&1 || fail "python3 is required to resolve the Compose volume name."
command -v tar >/dev/null 2>&1 || fail "tar is required to extract the uploads directory on the host."
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable or permission was denied."

echo "==> Validating the $ENVIRONMENT Compose configuration"
COMPOSE_CONFIG="$(compose config --format json)" || fail "Could not render the $ENVIRONMENT Compose configuration."
if ! VOLUME_NAME="$(printf '%s' "$COMPOSE_CONFIG" | python3 -c '
import json
import sys

config = json.load(sys.stdin)
volume = config.get("volumes", {}).get("openwebui_data", {})
if volume.get("external") is not True:
    raise SystemExit("Compose volume openwebui_data must be declared external.")
name = volume.get("name")
if not isinstance(name, str) or not name:
    raise SystemExit("Compose did not resolve the external Open WebUI volume name.")

mounts = config.get("services", {}).get("openwebui", {}).get("volumes", [])
if not any(mount.get("type") == "volume" and
           mount.get("source") == "openwebui_data" and
           mount.get("target") == "/data" for mount in mounts):
    raise SystemExit("Open WebUI must mount external volume openwebui_data at /data.")

print(name)
')"; then
  fail "Could not resolve and validate the external Open WebUI volume."
fi

valid_path_segment "$VOLUME_NAME" ||
  fail "Resolved volume name '$VOLUME_NAME' is not a safe directory name."
docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 ||
  fail "Open WebUI volume '$VOLUME_NAME' does not exist."

SERVICE_CONTAINER_OUTPUT="$(compose ps --all --quiet openwebui)" ||
  fail "Could not inspect the $ENVIRONMENT Open WebUI service."
SERVICE_CONTAINERS=()
if [[ -n "$SERVICE_CONTAINER_OUTPUT" ]]; then
  mapfile -t SERVICE_CONTAINERS <<< "$SERVICE_CONTAINER_OUTPUT"
fi
((${#SERVICE_CONTAINERS[@]} <= 1)) ||
  fail "More than one Open WebUI container was found for $ENVIRONMENT."

SERVICE_CONTAINER="${SERVICE_CONTAINERS[0]:-}"
SERVICE_CONTAINER_ID=""
SERVICE_RUNNING=false
if [[ -n "$SERVICE_CONTAINER" ]]; then
  SERVICE_CONTAINER_ID="$(docker inspect --format '{{.Id}}' "$SERVICE_CONTAINER")" ||
    fail "Could not inspect Open WebUI container '$SERVICE_CONTAINER'."
  ATTACHED_VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{if eq .Type "volume"}}{{.Name}}{{else}}NOT_A_VOLUME{{end}}{{end}}{{end}}' "$SERVICE_CONTAINER")" ||
    fail "Could not inspect the /data mount on Open WebUI container '$SERVICE_CONTAINER'."
  [[ "$ATTACHED_VOLUME" == "$VOLUME_NAME" ]] ||
    fail "The $ENVIRONMENT Open WebUI container uses '$ATTACHED_VOLUME' at /data, but Compose resolves '$VOLUME_NAME'. Refusing to back up a possibly stale configuration."

  if [[ "$(docker inspect --format '{{.State.Running}}' "$SERVICE_CONTAINER")" == true ]]; then
    SERVICE_RUNNING=true
  fi
fi

assert_expected_volume_users() {
  local expected_container_id="${1:-}"
  local active_containers
  local active_container

  active_containers="$(docker ps --no-trunc --quiet --filter "volume=$VOLUME_NAME")" ||
    fail "Could not inspect running containers using volume '$VOLUME_NAME'."
  while IFS= read -r active_container; do
    [[ -n "$active_container" ]] || continue
    if [[ -z "$expected_container_id" || "$active_container" != "$expected_container_id" ]]; then
      fail "Unexpected running container '$active_container' is using volume '$VOLUME_NAME'. Stop it before backing up."
    fi
  done <<< "$active_containers"
}

# Permit the expected Open WebUI container, but refuse other writers.
if [[ "$SERVICE_RUNNING" == true ]]; then
  assert_expected_volume_users "$SERVICE_CONTAINER_ID"
else
  assert_expected_volume_users
fi

# Ensure the helper image is available before stopping Open WebUI.
docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull "$HELPER_IMAGE"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
VOLUME_BACKUP_DIR="$BACKUP_ROOT/$INSTANCE/$ENVIRONMENT/$VOLUME_NAME"
SNAPSHOT_DIR="$VOLUME_BACKUP_DIR/$TIMESTAMP"
umask 077

ensure_private_directory() {
  local directory="$1"
  [[ ! -L "$directory" ]] || fail "Refusing to use symlinked backup directory '$directory'."
  if [[ -e "$directory" && ! -d "$directory" ]]; then
    fail "Backup path exists and is not a directory: $directory"
  fi
  mkdir -p -- "$directory" || fail "Could not create backup directory '$directory'."
  [[ -d "$directory" && ! -L "$directory" ]] ||
    fail "Backup path is not a real directory: $directory"
  chmod 700 -- "$directory" || fail "Could not restrict permissions on '$directory'."
}

ensure_private_directory "$BACKUP_ROOT"
ensure_private_directory "$BACKUP_ROOT/$INSTANCE"
ensure_private_directory "$BACKUP_ROOT/$INSTANCE/$ENVIRONMENT"
ensure_private_directory "$VOLUME_BACKUP_DIR"
[[ ! -e "$SNAPSHOT_DIR" && ! -L "$SNAPSHOT_DIR" ]] ||
  fail "Snapshot already exists: $SNAPSHOT_DIR"

STAGING_DIR="$(mktemp -d "$VOLUME_BACKUP_DIR/.${TIMESTAMP}.partial.XXXXXX")" ||
  fail "Could not create a staging directory under '$VOLUME_BACKUP_DIR'."

if [[ "$SERVICE_RUNNING" == true ]]; then
  SERVICE_NEEDS_RESTART=true
  echo "==> Stopping $ENVIRONMENT Open WebUI for a consistent uploads snapshot"
  compose stop --timeout 30 openwebui
fi

assert_expected_volume_users

echo "==> Extracting /data/uploads from volume '$VOLUME_NAME'"
set -o pipefail
docker run --rm --network none \
  --mount "type=volume,src=$VOLUME_NAME,dst=/data,readonly" \
  "$HELPER_IMAGE" sh -ec 'test -d /data/uploads || { echo "Missing /data/uploads in source volume" >&2; exit 1; }; tar -C /data/uploads -cf - .' |
  tar --extract --file=- --directory="$STAGING_DIR" --preserve-permissions --no-same-owner

mv -T --no-clobber -- "$STAGING_DIR" "$SNAPSHOT_DIR" ||
  fail "Could not finalize snapshot at '$SNAPSHOT_DIR'."
[[ ! -e "$STAGING_DIR" && -d "$SNAPSHOT_DIR" ]] ||
  fail "Snapshot destination appeared during backup; refusing to overwrite it."
STAGING_DIR=""

echo "==> Uploads snapshot saved to $SNAPSHOT_DIR"
echo "    This snapshot contains uploaded source files only; it does not contain Open WebUI database records or vector-store data."
