#!/bin/bash
# One-time developer setup: installs the pre-push release hook, checks gh, offers the signing cert.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Enabling the pre-push release hook (core.hooksPath = scripts/hooks)"
git config core.hooksPath scripts/hooks

echo "==> Checking GitHub CLI login"
if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh is not installed. Install it (brew install gh), run 'gh auth login', then re-run this script." >&2
    exit 1
fi
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
