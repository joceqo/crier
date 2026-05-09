#!/usr/bin/env bash
# Local-test install for OpenAI Codex CLI: build crier-emit and append the
# hook blocks to ~/.codex/config.toml. Bash can't safely round-trip TOML, so
# this script strips prior Crier-owned Codex hook blocks and appends a fresh
# managed block. A timestamped backup is taken before any change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${HOME}/.codex/config.toml"
BEGIN_MARKER="# >>> CRIER HOOKS — managed by Crier.app, do not edit"
END_MARKER="# <<< CRIER HOOKS"

codex_hooks_feature_key() {
    if [[ -n "${CRIER_CODEX_HOOKS_FEATURE_KEY:-}" ]]; then
        case "$CRIER_CODEX_HOOKS_FEATURE_KEY" in
            hooks|codex_hooks) echo "$CRIER_CODEX_HOOKS_FEATURE_KEY"; return ;;
            *) echo "CRIER_CODEX_HOOKS_FEATURE_KEY must be hooks or codex_hooks" >&2; exit 1 ;;
        esac
    fi

    if command -v codex >/dev/null 2>&1; then
        local features
        features="$(codex features list 2>/dev/null || true)"
        if printf '%s\n' "$features" | awk '{print $1}' | grep -qx hooks; then
            echo "hooks"
            return
        fi
        if printf '%s\n' "$features" | awk '{print $1}' | grep -qx codex_hooks; then
            echo "codex_hooks"
            return
        fi
    fi

    # Modern Codex uses `hooks`; fall back to it when Codex is not installed
    # or is too old to expose `codex features list`.
    echo "hooks"
}

ensure_codex_hooks_feature() {
    local key="$1"
    local old_key="codex_hooks"
    [[ "$key" == "codex_hooks" ]] && old_key="hooks"

    if ! grep -qE '^\[features\]' "$CONFIG"; then
        {
            echo
            echo "[features]"
            echo "$key = true"
        } >> "$CONFIG"
        return
    fi

    perl -0pi -e "s/^\\Q$old_key\\E\\s*=\\s*(true|false)\\s*$/$key = true/m" "$CONFIG"
    if ! awk -v key="$key" '
        $0 == "[features]" { in_features = 1; next }
        in_features && $0 ~ /^\[/ { in_features = 0 }
        in_features && $1 == key { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$CONFIG"; then
        perl -0pi -e "s/^\\[features\\]\\n/[features]\n$key = true\n/m" "$CONFIG"
    fi
}

strip_crier_codex_hooks() {
    perl -0pi -e '
        my $begin = quotemeta($ENV{"BEGIN_MARKER"});
        my $end = quotemeta($ENV{"END_MARKER"});

        s/\n*$begin.*?$end\n?//gs;

        for my $event (qw(Stop PermissionRequest)) {
            my $action = $event eq "Stop" ? "turn_done" : "needs_permission";
            s/\n*\[\[hooks\.\Q$event\E\]\]\s*\n\s*\[\[hooks\.\Q$event\E\.hooks\]\]\s*\n(?:(?!\n\[\[).)*?command\s*=\s*"[^"]*crier-emit codex \Q$action\E"(?:(?!\n\[\[).)*//gs;
            s/\n*\[\[hooks\.\Q$event\E\]\]\s*\n(?:(?!\n\[\[).)*?command\s*=\s*"[^"]*crier-emit codex \Q$action\E"(?:(?!\n\[\[).)*//gs;
        }
    ' "$CONFIG"
}

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

BACKUP="${CONFIG}.bak.$(date +%s)"
cp "$CONFIG" "$BACKUP"
echo "==> Backed up existing config to $BACKUP"

export BEGIN_MARKER END_MARKER
strip_crier_codex_hooks

FEATURE_KEY="$(codex_hooks_feature_key)"
ensure_codex_hooks_feature "$FEATURE_KEY"
echo "==> Enabled Codex hooks feature: [features].$FEATURE_KEY"

# Codex's hook TOML is two-level: [[hooks.<Event>]] is just a group header
# (it carries an optional `matcher`), and the actual handler goes in a
# nested [[hooks.<Event>.hooks]] table. Earlier versions of this script put
# the handler fields directly under [[hooks.Stop]] and Codex silently
# ignored them — verified against developers.openai.com/codex/hooks.
cat <<EOF >> "$CONFIG"

$BEGIN_MARKER

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
$END_MARKER
EOF

echo "==> Wired Crier hook entries in $CONFIG"
echo "    crier-emit: $EMIT"
echo
echo "Restart any running codex sessions to activate."
