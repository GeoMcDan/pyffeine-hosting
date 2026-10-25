#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat >&2 <<EOF
Usage: $0 <deploy|pull|start|logs> [arguments...]

Commands:
  deploy <prod|live|dev>        Update checkout and restart the deployment
  pull <prod|live|dev>          Pull images without restarting containers
  start <prod|live|dev> [--yes] Start the local checkout without Git updates
  logs <prod|live|dev>          Follow deployment logs
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

COMMAND="$1"
shift

case "$COMMAND" in
  deploy) SCRIPT="deploy.sh" ;;
  pull)   SCRIPT="pull-images.sh" ;;
  start)  SCRIPT="start-stack.sh" ;;
  logs)   SCRIPT="follow-logs.sh" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 2
    ;;
esac

exec "$SCRIPT_DIR/scripts/$SCRIPT" "$@"
