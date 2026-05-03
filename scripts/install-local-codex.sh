#!/usr/bin/env bash
# Local-test install for OpenAI Codex CLI: build crier-emit and append the
# hook blocks to ~/.codex/config.toml. Bash can't safely round-trip TOML, so
# this script *appends* and refuses to run if existing crier-emit entries are
# already present (re-running with a new path = remove the old block by hand
# first). A timestamped backup is taken before any change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${HOME}/.codex/config.toml"

# CRIER_EMIT_BIN lets callers (notably the test suite, which would otherwise
# nested-deadlock on `.build/`) skip the swift build and point at a binary
# they already built. Normal humans never set this.
if [[ -n "${CRIER_EMIT_BIN:-}" ]]; then
    EMIT="$CRIER_EMIT_BIN"
else
    command -v swift >/dev/null || { echo "Swift toolchain required" >&2; exit 1; }
    echo "==> Building crier-emit (release)"
    ( cd "$REPO_DIR" && swift build -c release --product crier-emit )
    EMIT="$REPO_DIR/.build/release/crier-emit"
fi
test -x "$EMIT" || { echo "build did not produce $EMIT" >&2; exit 1; }

mkdir -p "${HOME}/.codex"
[[ -f "$CONFIG" ]] || touch "$CONFIG"

if grep -q crier-emit "$CONFIG"; then
    echo "==> $CONFIG already contains crier-emit entries." >&2
    echo "    Remove them by hand and re-run if you need to update the path." >&2
    exit 1
fi

BACKUP="${CONFIG}.bak.$(date +%s)"
cp "$CONFIG" "$BACKUP"
echo "==> Backed up existing config to $BACKUP"

if ! grep -qE '^\[features\]' "$CONFIG"; then
    {
        echo
        echo "[features]"
        echo "codex_hooks = true"
    } >> "$CONFIG"
else
    echo "==> [features] section already exists; ensure it contains: codex_hooks = true"
fi

# Codex's hook TOML is two-level: [[hooks.<Event>]] is just a group header
# (it carries an optional `matcher`), and the actual handler goes in a
# nested [[hooks.<Event>.hooks]] table. Earlier versions of this script put
# the handler fields directly under [[hooks.Stop]] and Codex silently
# ignored them — verified against developers.openai.com/codex/hooks.
cat <<EOF >> "$CONFIG"

[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "$EMIT codex turn_done"
timeout = 10

[[hooks.PermissionRequest]]

[[hooks.PermissionRequest.hooks]]
type = "command"
command = "$EMIT codex needs_permission"
timeout = 10
EOF

echo "==> Appended Crier hook entries to $CONFIG"
echo "    crier-emit: $EMIT"
echo
echo "Restart any running codex sessions to activate."
