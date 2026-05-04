#!/usr/bin/env bash
# Installs the @crier/opencode-plugin into a stable per-user location and
# registers it with the OpenCode CLI so the Crier panel pops up when an
# OpenCode session goes idle / asks for permission.
#
# One-liner:
#
#   curl -fsSL https://raw.githubusercontent.com/joceqo/crier/main/scripts/install-opencode.sh | bash
#
# Re-runnable: pulls the latest plugin source, rebuilds, re-registers.
# Honours $CRIER_OPENCODE_PLUGIN_DIR if you want to override the install path.
set -euo pipefail

REPO_URL="https://github.com/joceqo/crier"
INSTALL_DIR="${CRIER_OPENCODE_PLUGIN_DIR:-$HOME/.local/share/crier/opencode-plugin}"

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "==> $1 required: $2" >&2
        exit 1
    }
}

require opencode "install from https://opencode.ai"
require git      "install Xcode CLT or 'brew install git'"
require npm      "install Node from https://nodejs.org"

mkdir -p "$(dirname "$INSTALL_DIR")"

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "==> Updating $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --depth 1 origin main
    git -C "$INSTALL_DIR" checkout -B main origin/main
else
    echo "==> Fetching plugin into $INSTALL_DIR (sparse clone)"
    rm -rf "$INSTALL_DIR"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    # Sparse checkout so we only pull packages/opencode-plugin, not the
    # whole Swift codebase + assets.
    git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$TMP/crier"
    git -C "$TMP/crier" sparse-checkout set packages/opencode-plugin
    mv "$TMP/crier/packages/opencode-plugin" "$INSTALL_DIR"
fi

echo "==> Building"
( cd "$INSTALL_DIR" && npm install --silent && npm run build --silent )

echo "==> npm link (makes @crier/opencode-plugin globally resolvable)"
( cd "$INSTALL_DIR" && npm link --silent )

echo "==> Registering plugin with opencode (global)"
if opencode plugin -g -f @crier/opencode-plugin </dev/null 2>/dev/null; then
    echo
    echo "Done. Restart any running OpenCode sessions; new turns will pop the Crier panel."
    exit 0
fi

# Fallback: the user's opencode CLI doesn't resolve linked packages, so
# write the plugin path directly into their global opencode.json.
echo "==> opencode plugin -g -f did not resolve the link — falling back to opencode.json"
CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
mkdir -p "$(dirname "$CONFIG")"
PLUGIN_ENTRY="$INSTALL_DIR/dist/index.js"

if command -v jq >/dev/null 2>&1 && [ -s "$CONFIG" ]; then
    TMP_CFG=$(mktemp)
    jq --arg p "$PLUGIN_ENTRY" '.plugin = ((.plugin // []) + [$p] | unique)' "$CONFIG" > "$TMP_CFG"
    mv "$TMP_CFG" "$CONFIG"
    echo "==> Added plugin entry to $CONFIG"
else
    cat <<EOF
Add this to $CONFIG manually:

  {
    "plugin": [
      "$PLUGIN_ENTRY"
    ]
  }

(Install jq for automatic merging.)
EOF
fi

echo
echo "Done. Restart any running OpenCode sessions."
