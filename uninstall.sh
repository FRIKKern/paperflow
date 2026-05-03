#!/usr/bin/env bash
# paperflow uninstaller — removes LaunchAgents, hooks, settings entries,
# and renderers. Does NOT delete ~/.claude/CLAUDE.md (your edits) or any
# specs/plans/grills you've written.

set -euo pipefail

log()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[1;33m•\033[0m %s\n' "$*"; }

USER_NAME="$(id -un)"
LABEL_PREFIX="${LABEL_PREFIX:-dev.${USER_NAME}}"
LR_LABEL="${LABEL_PREFIX}.docs-livereload"
BR_LABEL="${LABEL_PREFIX}.claude-bridge"

# 1. LaunchAgents
log "LaunchAgents"
for L in "$LR_LABEL" "$BR_LABEL"; do
    if launchctl print "gui/$(id -u)/$L" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$L" >/dev/null 2>&1 || true
        ok "booted out $L"
    else
        skip "$L not running"
    fi
    rm -f "$HOME/Library/LaunchAgents/$L.plist"
done

# 2. Hooks
log "Hooks"
rm -f "$HOME/.claude/hooks/inject-principles.sh" "$HOME/.claude/hooks/auto-open-doc.sh"
ok "removed"

# 3. settings.json — strip our hook entries
log "settings.json"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    TMP="$(mktemp)"
    jq '
      .hooks.UserPromptSubmit |= ((. // []) | map(select(
        (.hooks // []) | map(select(.command? | type == "string" and endswith("inject-principles.sh"))) | length == 0
      )))
      | .hooks.PostToolUse |= ((. // []) | map(select(
        (.hooks // []) | map(select(.command? | type == "string" and endswith("auto-open-doc.sh"))) | length == 0
      )))
      | (if (.hooks.UserPromptSubmit // []) == [] then del(.hooks.UserPromptSubmit) else . end)
      | (if (.hooks.PostToolUse      // []) == [] then del(.hooks.PostToolUse)      else . end)
      | (if (.hooks // {}) == {} then del(.hooks) else . end)
    ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
    ok "stripped paperflow hook entries"
fi

# 4. Renderers
log "Renderers"
for f in doc.css doc.js grill.css grill.js; do
    rm -f "$HOME/docs/superpowers/_lib/$f"
done
rmdir "$HOME/docs/superpowers/_lib" 2>/dev/null && ok "_lib removed (was empty)" || skip "_lib kept (other files inside)"

# 5. Skill
log "Skill"
rm -rf "$HOME/.claude/skills/grill-plan"
ok "grill-plan removed"

# 6. Helper
log "Helper"
rm -f "$HOME/.local/bin/paperflow-target"
ok "removed"

echo
log "Done. Your CLAUDE.md and any specs/plans/grills you wrote are untouched."
echo "  To remove npm-global live-server too:  npm uninstall -g live-server"
