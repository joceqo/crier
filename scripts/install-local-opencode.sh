#!/usr/bin/env bash
# Local-test install for OpenCode: build packages/opencode-plugin, npm-link it
# globally, and try to register it with opencode. If `opencode plugin -g -f`
# can't resolve a linked package, the script prints the manual fallback
# (adding the local path to opencode.json's "plugin" array).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$REPO_DIR/packages/opencode-plugin"

command -v opencode >/dev/null || { echo "opencode CLI required — install from https://opencode.ai" >&2; exit 1; }
command -v npm      >/dev/null || { echo "npm required" >&2; exit 1; }

echo "==> Building @crier/opencode-plugin"
( cd "$PKG_DIR" && npm install --silent && npm run build --silent )

echo "==> npm link (makes @crier/opencode-plugin globally resolvable)"
( cd "$PKG_DIR" && npm link --silent )

echo "==> Registering plugin with opencode (global)"
if opencode plugin -g -f @crier/opencode-plugin </dev/null; then
    echo
    echo "==> Done. New OpenCode sessions will POST events to http://127.0.0.1:8731/event."
else
    cat <<EOF >&2

opencode plugin install did not resolve the linked package.
Fallback — add this entry to ~/.config/opencode/opencode.json (or your project's opencode.json):

  {
    "plugin": [
      "$PKG_DIR/dist/index.js"
    ]
  }

Then restart any running opencode sessions.
EOF
    exit 1
fi
