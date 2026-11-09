#!/bin/bash
# One-time developer setup: installs the pre-push release hook, checks gh, offers the signing cert.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Checking GitHub CLI"
# Before touching git config: the hook needs gh, so don't install it without.
if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh is not installed. Install it (brew install gh), run 'gh auth login', then re-run this script." >&2
    exit 1
fi

echo "==> Enabling the pre-push release hook (core.hooksPath = scripts/hooks)"
current_hooks="$(git config --get core.hooksPath || true)"
if [[ -n "$current_hooks" && "$current_hooks" != "scripts/hooks" ]]; then
    echo "core.hooksPath is already set to \"$current_hooks\"; continuing replaces it, and hooks there stop running."
    read -r -p "Replace it with scripts/hooks? [y/N] " replace || replace="n"   # no input (EOF) means no
    case "$replace" in
        [yY]*) ;;
        *) echo "Left core.hooksPath alone; the release hook is not installed." >&2; exit 1 ;;
    esac
fi
git config core.hooksPath scripts/hooks

echo "==> Checking GitHub CLI login"
if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh is not logged in. Run 'gh auth login', then re-run this script." >&2
    exit 1
fi
echo "gh is authenticated."

echo "==> Signing certificate"
echo "Builds are signed with a self-signed \"Featherweight Self-Signed\" certificate so macOS keeps"
echo "its permissions across updates. Without it they are signed ad-hoc."
read -r -p "Create the certificate now? [y/N] " answer || answer="n"   # no input (EOF) means no
case "$answer" in
    [yY]*) scripts/create-signing-cert.sh ;;
    *) echo "Skipped. Run scripts/create-signing-cert.sh whenever you want it." ;;
esac

echo "Setup complete."
