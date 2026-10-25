#!/bin/bash
# ============================================================
# deploy.sh - update a deployment dir and restart the stack
#
# Usage:  ./deploy.sh [live|dev]
#
#   live  -> /home/george/n8n-compose   (branch: main)
#   dev   -> /home/george/pyffeine-dev  (branch: dev)
#
# Each deployment dir is a git clone of this repo. The real
# .env lives only in the deployment dir (gitignored) and is
# never stored in the repo.
# ============================================================
set -euo pipefail

TARGET="${1:-live}"

case "$TARGET" in
  live)
    DEPLOY_DIR="/home/george/n8n-compose"
    BRANCH="main"
    ;;
  dev)
    DEPLOY_DIR="/home/george/pyffeine-dev"
    BRANCH="dev"
    ;;
  *)
    echo "Usage: $0 [live|dev]"
    exit 1
    ;;
esac

echo "==> Deploying '$TARGET' (branch: $BRANCH) to $DEPLOY_DIR"

# Sanity checks
[ -d "$DEPLOY_DIR/.git" ] || { echo "ERROR: $DEPLOY_DIR is not a git clone"; exit 1; }
[ -f "$DEPLOY_DIR/docker-compose.yml" ] || { echo "ERROR: $DEPLOY_DIR/docker-compose.yml not found"; exit 1; }
[ -f "$DEPLOY_DIR/.env" ] || { echo "ERROR: $DEPLOY_DIR/.env not found - copy .env.example and fill it in"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not installed"; exit 1; }

# Determine Compose project name
case "$TARGET" in
  live) PROJECT_NAME="pyffeine-prod" ;;
  dev)  PROJECT_NAME="pyffeine-dev" ;;
  *)    PROJECT_NAME="pyffeine-$TARGET" ;;
esac

# Update + restart
cd "$DEPLOY_DIR"
git checkout "$BRANCH"
git pull origin "$BRANCH"
docker compose --project-name "$PROJECT_NAME" config >/dev/null
docker compose --project-name "$PROJECT_NAME" up -d

echo "==> Deploy complete."
echo "    Status: docker compose --project-name \"$PROJECT_NAME\" ps"
echo "    Logs:   docker compose --project-name \"$PROJECT_NAME\" logs -f"
