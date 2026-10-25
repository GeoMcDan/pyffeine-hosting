#!/bin/bash
# Follow logs for a deployment without relying on the current directory.
set -euo pipefail

usage() {
  echo "Usage: $0 <prod|live|dev>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

TARGET="$1"
case "$TARGET" in
  prod|live)
    DEPLOY_DIR="/home/george/n8n-compose"
    PROJECT_NAME="pyffeine-prod"
    ;;
  dev)
    DEPLOY_DIR="/home/george/pyffeine-dev"
    PROJECT_NAME="pyffeine-dev"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

[[ -f "$DEPLOY_DIR/docker-compose.yml" ]] || { echo "ERROR: $DEPLOY_DIR/docker-compose.yml not found" >&2; exit 1; }
[[ -f "$DEPLOY_DIR/.env" ]] || { echo "ERROR: $DEPLOY_DIR/.env not found" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not installed" >&2; exit 1; }

cd "$DEPLOY_DIR"
exec docker compose --project-name "$PROJECT_NAME" logs -f
