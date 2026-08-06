#!/bin/sh
# Clabar: установка хуков внутри devcontainer (идемпотентно).
# Кладите в .devcontainer/ проекта и вызывайте из postStartCommand.
# Нужны: curl (для самого хука) и python3 (для merge settings.json).
set -e

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CFG/hooks"

cat > "$CFG/hooks/clabar-hook.sh" <<'HOOK'
#!/bin/sh
# Clabar: forward Claude Code hook events to the menu bar app on the host.
h="${CLABAR_HOST:-host.docker.internal}"
p="${CLABAR_PORT:-8737}"
curl -s -m 3 -X POST "http://$h:$p/event" \
  -H "Content-Type: application/json" \
  -H "X-Clabar-Term: ${TERM_PROGRAM:-}" \
  -H "X-Clabar-Bundle: ${__CFBundleIdentifier:-}" \
  -H "X-Clabar-Remote: ${REMOTE_CONTAINERS:-}${CODESPACES:-}container" \
  --data-binary @- >/dev/null 2>&1 &
exit 0
HOOK
chmod +x "$CFG/hooks/clabar-hook.sh"

python3 - "$CFG/settings.json" <<'PY'
import json, os, sys

path = sys.argv[1]
root = {}
if os.path.exists(path):
    with open(path) as f:
        root = json.load(f)

hooks = root.setdefault("hooks", {})
cmd = 'sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh"'
subscriptions = [
    ("Notification", ""),
    ("Stop", ""),
    ("PermissionRequest", ""),
    ("PreToolUse", "AskUserQuestion|ExitPlanMode"),
    ("PostToolUseFailure", ""),
    ("SessionEnd", ""),
]
for event, matcher in subscriptions:
    groups = hooks.setdefault(event, [])
    if any("clabar-hook" in h.get("command", "")
           for g in groups for h in g.get("hooks", [])):
        continue
    group = {"hooks": [{"type": "command", "command": cmd, "async": True, "timeout": 5}]}
    if matcher:
        group["matcher"] = matcher
    groups.append(group)

with open(path, "w") as f:
    json.dump(root, f, indent=2, ensure_ascii=False)
PY

echo "Clabar hooks installed into $CFG"
