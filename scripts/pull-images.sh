#!/bin/bash
# ============================================================
# pull-images.sh - pull images for a deployment without restarting it
#
# Usage:  ./pull-images.sh [prod|live|dev]
#
#   prod/live -> /home/george/n8n-compose
#   dev   -> /home/george/pyffeine-dev
# ============================================================
set -euo pipefail

TARGET="${1:-live}"

case "$TARGET" in
  prod|live)
    DEPLOY_DIR="/home/george/n8n-compose"
    PROJECT_NAME="pyffeine-prod"
    ;;
  dev)
    DEPLOY_DIR="/home/george/pyffeine-dev"
    PROJECT_NAME="pyffeine-dev"
    ;;
  *)
    echo "Usage: $0 [prod|live|dev]"
    exit 1
    ;;
esac

echo "==> Pulling images for '$TARGET' ($PROJECT_NAME) from $DEPLOY_DIR"

# Sanity checks
[ -d "$DEPLOY_DIR" ] || { echo "ERROR: $DEPLOY_DIR does not exist"; exit 1; }
[ -f "$DEPLOY_DIR/docker-compose.yml" ] || { echo "ERROR: $DEPLOY_DIR/docker-compose.yml not found"; exit 1; }
[ -f "$DEPLOY_DIR/.env" ] || { echo "ERROR: $DEPLOY_DIR/.env not found - copy .env.example and fill it in"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not installed"; exit 1; }

cd "$DEPLOY_DIR"
docker compose --project-name "$PROJECT_NAME" config >/dev/null
docker compose --project-name "$PROJECT_NAME" pull

echo "==> Image pull complete. Running containers were not restarted."
