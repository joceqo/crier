#!/usr/bin/env bash
# Local-test install for Claude Code: build crier-emit, wire its absolute path
# into ~/.claude/settings.json hooks. Mirrors the event set the Superwhisper
# reference plugin hooks: Stop, Notification, PermissionRequest,
# PreToolUse:AskUserQuestion, UserPromptSubmit.
#
# Idempotent: re-running cleans up prior crier-emit entries before re-adding.
# A timestamped backup of settings.json is written each run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS="${HOME}/.claude/settings.json"

command -v jq    >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift toolchain is required" >&2; exit 1; }

echo "==> Building crier-emit (release)"
( cd "$REPO_DIR" && swift build -c release --product crier-emit )

EMIT="$REPO_DIR/.build/release/crier-emit"
test -x "$EMIT" || { echo "build did not produce $EMIT" >&2; exit 1; }

mkdir -p "${HOME}/.claude"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

BACKUP="${SETTINGS}.bak.$(date +%s)"
cp "$SETTINGS" "$BACKUP"
echo "==> Backed up existing settings to $BACKUP"

# Filter that strips any prior crier-emit entries from a hook-event array, so
# re-running this installer doesn't duplicate them and doesn't clobber other
# hooks the user has installed for the same events.
TMP="$(mktemp)"
jq --arg emit "$EMIT" '
  def strip_crier:
    map(select(((.hooks // []) | map(.command) | join(" ")) | test("crier-emit") | not));
  def add(event_arr; entry):
    event_arr |= ((. // []) | strip_crier) + [entry];

  .hooks //= {} |
  add(.hooks.Stop;
      {"hooks":[{"type":"command","command":"\($emit) claude-code turn_done","timeout":600}]}) |
  add(.hooks.Notification;
      {"hooks":[{"type":"command","command":"\($emit) claude-code needs_permission"}]}) |
  add(.hooks.PermissionRequest;
      {"hooks":[{"type":"command","command":"\($emit) claude-code needs_permission"}]}) |
  add(.hooks.PreToolUse;
      {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"\($emit) claude-code needs_input"}]}) |
  add(.hooks.UserPromptSubmit;
      {"hooks":[{"type":"command","command":"\($emit) claude-code dismiss"}]})
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

# Install BOTH a /crier skill (matches @superwhisper's layout, claude-code
# may invoke it semantically) AND a /crier command (guaranteed slash-invokable
# regardless of how skill dispatch is configured). Both touch the same flag
# file, so they're interchangeable.
SKILLS_DIR="${HOME}/.claude/skills/crier"
SRC_SKILL="$REPO_DIR/assets/claude-skills/crier/SKILL.md"
if [[ -f "$SRC_SKILL" ]]; then
    mkdir -p "$SKILLS_DIR"
    cp "$SRC_SKILL" "$SKILLS_DIR/SKILL.md"
    echo "==> Installed skill at $SKILLS_DIR/SKILL.md"
fi

COMMANDS_DIR="${HOME}/.claude/commands"
SRC_CMD="$REPO_DIR/assets/claude-commands/crier.md"
if [[ -f "$SRC_CMD" ]]; then
    mkdir -p "$COMMANDS_DIR"
    cp "$SRC_CMD" "$COMMANDS_DIR/crier.md"
    echo "==> Installed slash command at $COMMANDS_DIR/crier.md"
fi

echo "==> Wired hooks in $SETTINGS"
echo "    crier-emit: $EMIT"
echo
echo "Restart Claude Code, then:"
echo "  /hooks       — verify Crier is registered"
echo "  /crier off   — disable Crier for the current session"
echo "  /crier on    — re-enable"
echo "If you move or rebuild the repo to a different path, re-run this script."
