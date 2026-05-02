---
name: crier
description: Toggle Crier overlay integration (on/off/toggle) for the current project directory
args: on|off or empty to toggle
---

Run this bash command exactly:

```bash
h=$(echo -n "$PWD" | md5 -q 2>/dev/null || echo -n "$PWD" | md5sum | cut -d' ' -f1); f="/tmp/crier-agent/disabled-$h"; mkdir -p /tmp/crier-agent; case "$ARGUMENTS" in on) rm -f "$f"; echo "Crier: ON" ;; off) touch "$f"; echo "Crier: OFF" ;; *) [ -f "$f" ] && { rm -f "$f"; echo "Crier: ON"; } || { touch "$f"; echo "Crier: OFF"; } ;; esac
```

Report the single-line output to the user. Nothing else.
