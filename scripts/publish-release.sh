#!/bin/bash
# Usage: scripts/publish-release.sh VERSION SHA REMOTE
# Run detached by the pre-push hook. Waits (up to 10 minutes) for SHA to be on REMOTE's main (as its
# tip, or an ancestor of it), then creates the GitHub release from build/release/Featherweight-VERSION.zip.
# Does nothing if the release already exists. Notifies either way.
# Test knobs: FEATHERWEIGHT_POLL_INTERVAL (default 5s), FEATHERWEIGHT_POLL_TIMEOUT (default 600s).
set -euo pipefail

export GIT_TERMINAL_PROMPT=0   # detached: a credential prompt would hang or fail, never wait

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

if [[ $# -ne 3 ]]; then
    echo "usage: scripts/publish-release.sh VERSION SHA REMOTE" >&2
    exit 2
fi
VERSION="$1"
SHA="$2"
REMOTE="$3"
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

# True once SHA is the remote main's tip, or an ancestor of it (later commits may have landed already).
main_has_sha() {
    [[ -n "$remote" ]] || return 1
    [[ "$remote" == "$SHA" ]] && return 0
    git fetch --quiet "$REMOTE" refs/heads/main </dev/null >/dev/null 2>&1 || return 1
    git merge-base --is-ancestor "$SHA" FETCH_HEAD 2>/dev/null
}

log "waiting up to ${TIMEOUT}s for $REMOTE/main to reach $SHA"
SECONDS=0
while :; do
    remote="$(git ls-remote "$REMOTE" refs/heads/main 2>/dev/null </dev/null | cut -f1 | head -n1 || true)"
    main_has_sha && break
    if (( SECONDS >= TIMEOUT )); then
        fail "$REMOTE/main never reached $SHA within ${TIMEOUT}s (last seen: ${remote:-nothing}); was the push rejected?"
    fi
    sleep "$INTERVAL"
done

if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 </dev/null; then
    log "release v$VERSION already exists; nothing to do"
    notify "Featherweight $VERSION is already published."
    FINISHED=1
    exit 0
fi

# Release notes: this version's section of CHANGELOG.md at the pushed commit, or notes
# generated from the commits when there is no such section.
NOTES_ARGS=(--generate-notes)
NOTES_FILE="$(mktemp -t featherweight-notes)"
if git show "$SHA:CHANGELOG.md" 2>/dev/null \
        | awk -v v="$VERSION" '
            index($0, "## [" v "]") == 1 { found = 1; next }
            found && /^## \[/ { exit }
            found { print }' > "$NOTES_FILE" \
        && grep -q '[^[:space:]]' "$NOTES_FILE"; then
    NOTES_ARGS=(--notes-file "$NOTES_FILE")
    log "using the CHANGELOG.md section for v$VERSION as release notes"
fi

log "main has $SHA; creating release v$VERSION"
if ! gh release create "v$VERSION" "$ZIP" --repo "$REPO" --target "$SHA" \
        --title "Featherweight $VERSION" "${NOTES_ARGS[@]}" </dev/null; then
    fail "gh release create failed"
fi

rm -f "$NOTES_FILE"
log "published v$VERSION"
notify "Featherweight $VERSION is published."
FINISHED=1
