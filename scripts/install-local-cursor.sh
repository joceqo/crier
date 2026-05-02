#!/usr/bin/env bash
# Local-test install for Cursor CLI: build crier-emit, idempotently merge
# hook entries into ~/.cursor/hooks.json. Re-running cleans up prior
# crier-emit entries before re-adding (so updating the binary path is safe).
# A timestamped backup of hooks.json is written each run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="${HOME}/.cursor/hooks.json"

command -v jq    >/dev/null || { echo "jq required (brew install jq)" >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift toolchain required" >&2; exit 1; }

echo "==> Building crier-emit (release)"
( cd "$REPO_DIR" && swift build -c release --product crier-emit )

EMIT="$REPO_DIR/.build/release/crier-emit"
test -x "$EMIT" || { echo "build did not produce $EMIT" >&2; exit 1; }

mkdir -p "${HOME}/.cursor"
[[ -f "$HOOKS" ]] || echo '{"version":1,"hooks":{}}' > "$HOOKS"

BACKUP="${HOOKS}.bak.$(date +%s)"
cp "$HOOKS" "$BACKUP"
echo "==> Backed up existing hooks to $BACKUP"

TMP="$(mktemp)"
jq --arg emit "$EMIT" '
  def strip_crier:
    map(select((.command // "") | test("crier-emit") | not));
  def add(arr; entry):
    arr |= ((. // []) | strip_crier) + [entry];

  .version //= 1 |
  .hooks //= {} |
  add(.hooks.stop;
      {"command":"\($emit) cursor turn_done"}) |
  add(.hooks.beforeShellExecution;
      {"command":"\($emit) cursor needs_permission"})
' "$HOOKS" > "$TMP" && mv "$TMP" "$HOOKS"

echo "==> Wired hooks in $HOOKS"
echo "    crier-emit: $EMIT"
echo
echo "Restart any running cursor-agent sessions to activate."
