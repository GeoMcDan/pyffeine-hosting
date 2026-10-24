#!/usr/bin/env bash
# Start the stack from the current deployment checkout without checking out or pulling changes.
set -euo pipefail

usage() {
  echo "Usage: $0 <live|dev> [--yes]" >&2
}

TARGET=""
YES=false
for arg in "$@"; do
  case "$arg" in
    live|dev)
      if [[ -n "$TARGET" ]]; then usage; exit 2; fi
      TARGET="$arg"
      ;;
    --yes)
      if [[ "$YES" == true ]]; then usage; exit 2; fi
      YES=true
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
done

if [[ -z "$TARGET" ]]; then usage; exit 2; fi

case "$TARGET" in
  live)
    DEPLOY_DIR="/home/george/n8n-compose"
    BRANCH="main"
    PROJECT_NAME="pyffeine-prod"
    ;;
  dev)
    DEPLOY_DIR="/home/george/pyffeine-dev"
    BRANCH="dev"
    PROJECT_NAME="pyffeine-dev"
    ;;
esac

CURRENT_DIR="$(pwd -P)"
if [[ "$CURRENT_DIR" != "$DEPLOY_DIR" ]]; then
  echo "ERROR: '$TARGET' can only be started from $DEPLOY_DIR (current directory: $CURRENT_DIR)." >&2
  exit 1
fi

[[ -d .git ]] || { echo "ERROR: $DEPLOY_DIR is not a git clone" >&2; exit 1; }
[[ -f .env ]] || { echo "ERROR: $DEPLOY_DIR/.env not found - copy .env.example and fill it in" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not installed" >&2; exit 1; }

WARNINGS=()
CURRENT_BRANCH="$(git branch --show-current)"
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
  WARNINGS+=("checked-out branch is '$CURRENT_BRANCH', expected '$BRANCH'")
fi

if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  WARNINGS+=("the worktree, index, or untracked files contain local changes")
fi

TRACKING_REF="refs/remotes/origin/$BRANCH"
if ! git fetch origin "$BRANCH"; then
  WARNINGS+=("could not fetch origin/$BRANCH; remote divergence cannot be checked reliably")
fi

if git rev-parse --verify "$TRACKING_REF^{commit}" >/dev/null 2>&1; then
  TRACKING_COMMIT="$(git rev-parse "$TRACKING_REF^{commit}")"
  HEAD_COMMIT="$(git rev-parse HEAD)"
  if [[ "$HEAD_COMMIT" != "$TRACKING_COMMIT" ]]; then
    WARNINGS+=("HEAD does not match the locally cached origin/$BRANCH commit")
  fi
else
  WARNINGS+=("origin/$BRANCH has no locally cached commit, so remote divergence cannot be checked")
fi

echo "==> Starting '$TARGET' from $CURRENT_DIR (project: $PROJECT_NAME)"
if ((${#WARNINGS[@]})); then
  echo "WARNING: this applies the Compose configuration in this checkout; services may be recreated and configuration or volume changes can affect the running stack."
  for warning in "${WARNINGS[@]}"; do
    echo "  - $warning"
  done
  if [[ "$YES" != true ]]; then
    if [[ ! -r /dev/tty ]] || ! IFS= read -r -p "Continue without checkout or pull? [y/N] " answer </dev/tty; then
      echo "Aborted: confirmation unavailable." >&2
      exit 1
    fi
    case "$answer" in
      y|Y|yes|YES|Yes) ;;
      *) echo "Aborted."; exit 1 ;;
    esac
  fi
fi

docker compose --project-name "$PROJECT_NAME" config >/dev/null
docker compose --project-name "$PROJECT_NAME" up -d

echo "==> Stack started."
echo "    Status: docker compose --project-name $PROJECT_NAME ps"
echo "    Logs:   docker compose --project-name $PROJECT_NAME logs -f"
