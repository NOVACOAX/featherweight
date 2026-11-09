#!/bin/bash
# Usage: scripts/publish-release.sh VERSION SHA
# Run detached by the pre-push hook. Waits (up to 10 minutes) for SHA to arrive as origin's main,
# then creates the GitHub release from build/release/Featherweight-VERSION.zip. Notifies either way.
# Test knobs: FEATHERWEIGHT_POLL_INTERVAL (default 5s), FEATHERWEIGHT_POLL_TIMEOUT (default 600s).
set -euo pipefail

REPO="NOVACOAX/featherweight"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INTERVAL="${FEATHERWEIGHT_POLL_INTERVAL:-5}"
TIMEOUT="${FEATHERWEIGHT_POLL_TIMEOUT:-600}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] publish-release: $*"; }

notify() {
    local message="${1//\"/\'}"
    osascript -e "display notification \"$message\" with title \"Featherweight release\"" >/dev/null 2>&1 || true
}

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/publish-release.sh VERSION SHA" >&2
    exit 2
fi
VERSION="$1"
SHA="$2"
ZIP="build/release/Featherweight-$VERSION.zip"

FINISHED=0
fail() {
    log "FAILED: $*"
    notify "Release v$VERSION failed: $*"
    FINISHED=1
    exit 1
}
# Anything unexpected (set -e) still ends with a notification.
trap '[[ "$FINISHED" == 1 ]] || { log "FAILED: unexpected error"; notify "Release v$VERSION failed (see build/release/publish.log)"; }' EXIT

log "start v$VERSION at $SHA"
[[ -f "$ZIP" ]] || fail "$ZIP is missing"

if ! gh repo view "$REPO" >/dev/null 2>&1 </dev/null; then
    log "Create the repo and push main, then publish by hand: gh release create v$VERSION $ZIP --repo $REPO --target $SHA --title \"Featherweight $VERSION\" --generate-notes"
    fail "GitHub repo $REPO does not exist yet (or gh cannot see it)"
fi

log "waiting up to ${TIMEOUT}s for origin/main to reach $SHA"
SECONDS=0
while :; do
    remote="$(git ls-remote origin refs/heads/main 2>/dev/null </dev/null | cut -f1 | head -n1 || true)"
    [[ "$remote" == "$SHA" ]] && break
    if (( SECONDS >= TIMEOUT )); then
        fail "origin/main never reached $SHA within ${TIMEOUT}s (last seen: ${remote:-nothing}); was the push rejected?"
    fi
    sleep "$INTERVAL"
done

log "main is at $SHA; creating release v$VERSION"
if ! gh release create "v$VERSION" "$ZIP" --repo "$REPO" --target "$SHA" \
        --title "Featherweight $VERSION" --generate-notes </dev/null; then
    fail "gh release create failed"
fi

log "published v$VERSION"
notify "Featherweight $VERSION is published."
FINISHED=1
