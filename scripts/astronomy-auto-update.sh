#!/usr/bin/env bash
# astronomy-auto-update.sh — watch the astronomy repo's main branch and, when a
# new commit is pushed, run the local update loop: pull the astronomy clone,
# build the arm64 image + merge the multi-arch manifest (amd64 from CI) via
# `make astronomy-image`, bump the image digest in apps/astronomy (k8s-research),
# commit and sync ArgoCD.
#
# Usage:
#   astronomy-auto-update.sh --once     # single pass (foreground)
#   astronomy-auto-update.sh [--loop]   # continuous loop (default)
#
# Env (defaults): ASTRONOMY_DIR, ASTRONOMY_REMOTE, IMAGE, INTERVAL, LOG.
set -u

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPTS_DIR")"

ASTRONOMY_DIR="${ASTRONOMY_DIR:-$HOME/src/astronomy.aursand.no}"
ASTRONOMY_REMOTE="${ASTRONOMY_REMOTE:-https://github.com/toreau/astronomy.aursand.no.git}"
IMAGE="${IMAGE:-ghcr.io/toreau/astronomy-api}"
STATE_DIR="$REPO_ROOT/.astro-update"
STATE="$STATE_DIR/last-sha"
LOG="${LOG:-/tmp/astronomy-auto-update.log}"
INTERVAL="${INTERVAL:-60}"

# Files whose image digest we bump (all share the astronomy-api digest).
FILES=(
  "$REPO_ROOT/apps/astronomy/api.yaml"
  "$REPO_ROOT/apps/astronomy/ingest/ingest-naif.yaml"
  "$REPO_ROOT/apps/astronomy/ingest/ingest-datasets.yaml"
  "$REPO_ROOT/apps/astronomy/ingest/ingest-omm.yaml"
)

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

remote_sha() { git ls-remote "$ASTRONOMY_REMOTE" refs/heads/main | awk '{print $1}'; }

check_prereqs() {
  command -v docker >/dev/null || { log "error: docker not on PATH"; return 1; }
  command -v gh >/dev/null || { log "error: gh not on PATH"; return 1; }
  command -v kubectl >/dev/null || { log "error: kubectl not on PATH"; return 1; }
  command -v argocd >/dev/null || { log "error: argocd not on PATH"; return 1; }
  kubectl get nodes >/dev/null 2>&1 || { log "warn: cluster not reachable"; return 1; }
  pgrep -f 'git daemon' >/dev/null || { log "warn: git daemon not running"; return 1; }
  return 0
}

run_cycle() {
  local current last digest

  current="$(remote_sha)" || { log "warn: could not reach $ASTRONOMY_REMOTE"; return 1; }

  if [ ! -f "$STATE" ]; then
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$current" > "$STATE"
    log "baseline recorded ($current) — no build on first run"
    return 0
  fi

  last="$(cat "$STATE")"
  [ "$current" = "$last" ] && { log "up to date ($current)"; return 0; }
  log "new astronomy commit: ${last:0:7} -> ${current:0:7}"

  check_prereqs || { log "warn: prerequisites not met; skipping cycle"; return 1; }

  # Pull the astronomy clone (ff-only; skip if dirty/diverged — never clobber edits).
  if ! git -C "$ASTRONOMY_DIR" pull --ff-only origin main >/dev/null 2>&1; then
    log "warn: astronomy clone not fast-forwardable (uncommitted/diverged?); skipping"
    return 1
  fi
  if [ "$(git -C "$ASTRONOMY_DIR" rev-parse HEAD)" != "$current" ]; then
    log "warn: astronomy clone HEAD != remote main; skipping"
    return 1
  fi

  # Wait for CI's amd64 image before merging (avoids a half (arm64-only) manifest).
  if ! docker buildx imagetools inspect "$IMAGE:main-$current" >/dev/null 2>&1; then
    log "info: CI image not ready yet ($IMAGE:main-${current:0:7}); retrying later"
    return 1
  fi

  # Build arm64 + merge multi-arch manifest (k8s-research Makefile; guards HEAD==origin/main).
  if ! (cd "$REPO_ROOT" && make astronomy-image >/dev/null 2>&1); then
    log "error: make astronomy-image failed"
    return 1
  fi

  digest="$(docker buildx imagetools inspect "$IMAGE:main-$current" --format '{{.Manifest.Digest}}' 2>/dev/null)" \
    || { log "error: could not resolve digest for $IMAGE:main-${current:0:7}"; return 1; }
  digest="${digest#sha256:}"

  # Safety: don't clobber uncommitted edits to the files we bump.
  if ! git -C "$REPO_ROOT" diff --quiet -- "${FILES[@]}"; then
    log "warn: uncommitted changes in apps/astronomy; skipping digest bump"
    return 1
  fi

  for f in "${FILES[@]}"; do
    sed -i '' -E "s#(image: ghcr.io/toreau/astronomy-api@sha256:)[0-9a-f]{64}#\1${digest}#" "$f"
  done

  if git -C "$REPO_ROOT" diff --quiet -- "${FILES[@]}"; then
    log "info: digest already current ($digest); no commit needed"
  else
    (cd "$REPO_ROOT" && git add apps/astronomy && git commit -q -m "astronomy: bump image digest to ${current:0:7}") \
      || { log "error: commit failed"; return 1; }
    log "committed digest bump ${digest:0:12}"
  fi

  (cd "$REPO_ROOT" && make argo-sync >/dev/null 2>&1) || { log "error: argo-sync failed"; return 1; }
  kubectl -n astronomy rollout status deploy/astronomy-api --timeout=300s >/dev/null 2>&1 \
    || { log "error: astronomy-api rollout did not complete; will retry"; return 1; }

  printf '%s\n' "$current" > "$STATE"
  log "done: astronomy-api now at ${digest:0:12} (${current:0:7})"
  return 0
}

case "${1:-loop}" in
  --once) run_cycle; exit $? ;;
  --loop|loop) ;;
  --help|-h)
    sed -n '2,10p' "$0"; exit 0 ;;
  *) log "unknown arg: $1 (use --once or --loop)"; exit 2 ;;
esac

while true; do
  run_cycle
  sleep "$INTERVAL"
done
