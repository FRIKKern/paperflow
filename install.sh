#!/usr/bin/env bash
# paperflow installer — idempotent. Safe to re-run.
#
# Installs the full doc-workflow stack:
#   - live-server LaunchAgent (~/docs hot reload, port 8765)
#   - claude-bridge LaunchAgent (browser → terminal, port 8766)
#   - shared web renderers in ~/docs/superpowers/_lib/
#   - Claude Code hooks (inject-principles, auto-open-doc)
#   - grill-plan skill at ~/.claude/skills/grill-plan/
#   - terminal-target helper at ~/.local/bin/paperflow-target
#   - ~/.claude/CLAUDE.md (only if missing)
#
# After install, open /hooks once in any running Claude Code session
# (or restart) so hooks are picked up.

set -euo pipefail

log()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[1;33m•\033[0m %s\n' "$*"; }
err()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; }

REPO="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(id -un)"

# Configurable — defaults are reasonable. Override before running:
#   LABEL_PREFIX=dev.youralias bash install.sh
LABEL_PREFIX="${LABEL_PREFIX:-dev.${USER_NAME}}"
LR_LABEL="${LABEL_PREFIX}.docs-livereload"
BR_LABEL="${LABEL_PREFIX}.claude-bridge"

# ─── 0. Pre-flight ─────────────────────────────────────────────────
log "Pre-flight"

# Node 22+ — check (but locate the real binary later in step 2)
_PREFLIGHT_NODE_OK=0
if [ -d "$HOME/.nvm/versions/node" ] && ls -d "$HOME/.nvm/versions/node"/v22.*/bin/node >/dev/null 2>&1; then
    _PREFLIGHT_NODE_OK=1
elif command -v node >/dev/null 2>&1; then
    _NV="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
    [ "${_NV:-0}" -ge 22 ] && _PREFLIGHT_NODE_OK=1
fi
if [ "$_PREFLIGHT_NODE_OK" -ne 1 ]; then
    err "Node 22 or later is required. Install with one of:"
    printf '      brew install node           (simplest)\n'
    printf '      brew install nvm && nvm install 22\n\n'
    printf '    Then re-run: bash install.sh\n'
    exit 1
fi

# jq — required for settings.json merge
if ! command -v jq >/dev/null 2>&1; then
    err "jq is required. Install with: brew install jq"
    exit 1
fi

ok "ready"

# ─── 1. Directories ────────────────────────────────────────────────
log "Directories"
mkdir -p "$HOME/docs/superpowers/specs" \
         "$HOME/docs/superpowers/plans" \
         "$HOME/docs/superpowers/grills" \
         "$HOME/docs/superpowers/notes" \
         "$HOME/docs/superpowers/captures" \
         "$HOME/docs/superpowers/changelog" \
         "$HOME/docs/superpowers/missions" \
         "$HOME/docs/superpowers/_lib" \
         "$HOME/.paperflow" \
         "$HOME/.local/bin" \
         "$HOME/.local/log" \
         "$HOME/.claude/hooks" \
         "$HOME/.claude/skills/grill-plan" \
         "$HOME/.claude/skills/paperflow-install" \
         "$HOME/.claude/skills/discuss" \
         "$HOME/.claude/skills/pre-flight-capture" \
         "$HOME/.claude/skills/write-changelog" \
         "$HOME/.claude/skills/mission-create" \
         "$HOME/.claude/skills/mission-snapshot" \
         "$HOME/.claude/skills/mission-continue" \
         "$HOME/Library/LaunchAgents"
ok "ready"

# ─── 2. Detect Node v22+ ────────────────────────────────────────────
log "Node.js"
NODE_BIN=""
if [ -d "$HOME/.nvm/versions/node" ]; then
    NODE_BIN="$(ls -d "$HOME/.nvm/versions/node"/v22.*/bin/node 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -z "$NODE_BIN" ] && command -v node >/dev/null 2>&1; then
    NV="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
    if [ "${NV:-0}" -ge 22 ]; then NODE_BIN="$(command -v node)"; fi
fi
if [ -z "$NODE_BIN" ]; then
    err "Node 22 or later is required. Install with one of:"
    printf '      brew install node           (simplest)\n'
    printf '      brew install nvm && nvm install 22\n\n'
    printf '    Then re-run: bash install.sh\n'
    exit 1
fi
NODE_BIN_DIR="$(dirname "$NODE_BIN")"
ok "$NODE_BIN ($("$NODE_BIN" --version))"

# ─── 3. live-server (npm global) ────────────────────────────────────
log "live-server"
LIVE_SERVER="$NODE_BIN_DIR/live-server"
if [ -x "$LIVE_SERVER" ]; then
    skip "already installed"
else
    "$NODE_BIN_DIR/npm" install -g live-server >/dev/null 2>&1
    ok "installed"
fi

LIVE_SERVER_JS="$(readlink "$LIVE_SERVER" 2>/dev/null || echo "")"
if [ -n "$LIVE_SERVER_JS" ]; then
    case "$LIVE_SERVER_JS" in
        /*) ;;
        *)  LIVE_SERVER_JS="$NODE_BIN_DIR/$LIVE_SERVER_JS" ;;
    esac
    LIVE_SERVER_JS="$(cd "$(dirname "$LIVE_SERVER_JS")" && pwd)/$(basename "$LIVE_SERVER_JS")"
else
    LIVE_SERVER_JS="$LIVE_SERVER"
fi
ok "entry: $LIVE_SERVER_JS"

# ─── helper: render template with __VAR__ substitution ──────────────
render() {
    local src="$1" dst="$2"
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__USER__|$USER_NAME|g" \
        -e "s|__LABEL__|$3|g" \
        -e "s|__NODE_BIN__|$NODE_BIN|g" \
        -e "s|__NODE_BIN_DIR__|$NODE_BIN_DIR|g" \
        -e "s|__LIVE_SERVER_JS__|$LIVE_SERVER_JS|g" \
        -e "s|__BRIDGE_JS__|$REPO/bin/claude-bridge.js|g" \
        -e "s|__BRIDGE_DIR__|$REPO/bin|g" \
        -e "s|__LR_LABEL__|$LR_LABEL|g" \
        -e "s|__BR_LABEL__|$BR_LABEL|g" \
        "$src" > "$dst"
}

reload_agent() {
    local label="$1" plist="$2"
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    else
        launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    fi
}

# ─── 4. live-server LaunchAgent ─────────────────────────────────────
log "LaunchAgent: $LR_LABEL"
LR_PLIST="$HOME/Library/LaunchAgents/$LR_LABEL.plist"
render "$REPO/launchagents/docs-livereload.plist.tmpl" "$LR_PLIST" "$LR_LABEL"
reload_agent "$LR_LABEL" "$LR_PLIST"
sleep 1
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8765/" 2>/dev/null | grep -q 200; then
    ok "up at http://localhost:8765"
else
    err "not reachable — check $HOME/.local/log/docs-livereload.err.log"
fi

# ─── 5. claude-bridge LaunchAgent ───────────────────────────────────
log "LaunchAgent: $BR_LABEL"
BR_PLIST="$HOME/Library/LaunchAgents/$BR_LABEL.plist"
render "$REPO/launchagents/claude-bridge.plist.tmpl" "$BR_PLIST" "$BR_LABEL"
reload_agent "$BR_LABEL" "$BR_PLIST"
sleep 1
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8766/" 2>/dev/null | grep -q 200; then
    ok "up at http://localhost:8766"
else
    err "not reachable — check $HOME/.local/log/claude-bridge.err.log"
fi

# ─── 6. Shared renderers in ~/docs/superpowers/_lib/ ────────────────
log "Renderers"
for f in doc.css doc.js grill.css grill.js mermaid-zoom.css mermaid-zoom.js live-render.css live-render.js; do
    cp "$REPO/lib/$f" "$HOME/docs/superpowers/_lib/$f"
    ok "$f"
done

# ─── 7. Hooks ───────────────────────────────────────────────────────
log "Hooks"
for f in inject-principles.sh auto-open-doc.sh; do
    cp "$REPO/hooks/$f" "$HOME/.claude/hooks/$f"
    chmod +x "$HOME/.claude/hooks/$f"
    ok "$f"
done

# ─── 8. settings.json merge ─────────────────────────────────────────
log "settings.json"
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if jq -e '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command? | type == "string" and endswith("inject-principles.sh"))' "$SETTINGS" >/dev/null 2>&1; then
    skip "UserPromptSubmit hook already present"
else
    TMP="$(mktemp)"
    jq '.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{
        hooks: [{ type: "command",
                  command: "$HOME/.claude/hooks/inject-principles.sh",
                  timeout: 5 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged UserPromptSubmit"
fi

if jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command? | type == "string" and endswith("auto-open-doc.sh"))' "$SETTINGS" >/dev/null 2>&1; then
    skip "PostToolUse hook already present"
else
    TMP="$(mktemp)"
    jq '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
        matcher: "Write|Edit",
        hooks: [{ type: "command",
                  command: "$HOME/.claude/hooks/auto-open-doc.sh",
                  timeout: 3 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged PostToolUse"
fi

# ─── 9. Skills ──────────────────────────────────────────────────────
log "Skills"
for s in grill-plan paperflow-install discuss pre-flight-capture write-changelog mission-create mission-snapshot mission-continue; do
    if [ -f "$REPO/skills/$s/SKILL.md" ]; then
        mkdir -p "$HOME/.claude/skills/$s"
        cp "$REPO/skills/$s/SKILL.md" "$HOME/.claude/skills/$s/SKILL.md"
        ok "$s"
    else
        err "$s : missing template"
    fi
done

# ─── 10. terminal-target helper at ~/.local/bin/paperflow-target ───
log "Helper: paperflow-target"
cp "$REPO/bin/get-terminal-target.sh" "$HOME/.local/bin/paperflow-target"
chmod +x "$HOME/.local/bin/paperflow-target"
ok "installed at ~/.local/bin/paperflow-target"

# ─── 10b. mission launcher at ~/.local/bin/paperflow-continue ──────
log "Helper: paperflow-continue"
cp "$REPO/bin/paperflow-continue" "$HOME/.local/bin/paperflow-continue"
chmod +x "$HOME/.local/bin/paperflow-continue"
ok "installed at ~/.local/bin/paperflow-continue"

# ─── 11. CLAUDE.md (only if missing) ────────────────────────────────
log "~/.claude/CLAUDE.md"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    skip "exists (not overwriting — edit manually to refresh)"
else
    render "$REPO/claude-md.tmpl" "$CLAUDE_MD" ""
    ok "written"
fi

# ─── 12. Status ─────────────────────────────────────────────────────
echo
log "Status"
{
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8765/" 2>/dev/null | grep -q 200; then
        ok "live-server   : up    (http://localhost:8765)"
    else
        err "live-server   : DOWN"
    fi
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8766/" 2>/dev/null | grep -q 200; then
        ok "claude-bridge : up    (http://localhost:8766)"
    else
        err "claude-bridge : DOWN"
    fi
    [ -f "$CLAUDE_MD" ]                                && ok "CLAUDE.md     : present"    || err "CLAUDE.md     : missing"
    [ -x "$HOME/.claude/hooks/inject-principles.sh" ]  && ok "inject hook   : executable" || err "inject hook   : missing"
    [ -x "$HOME/.claude/hooks/auto-open-doc.sh" ]      && ok "open hook     : executable" || err "open hook     : missing"
    [ -f "$HOME/docs/superpowers/_lib/doc.js" ]        && ok "doc renderer  : present"    || err "doc renderer  : missing"
    [ -f "$HOME/docs/superpowers/_lib/grill.js" ]      && ok "grill render. : present"    || err "grill render. : missing"
    [ -f "$HOME/.claude/skills/grill-plan/SKILL.md" ]         && ok "grill skill   : present"    || err "grill skill   : missing"
    [ -f "$HOME/.claude/skills/paperflow-install/SKILL.md" ]  && ok "install skill : present"    || err "install skill : missing"
    [ -f "$HOME/.claude/skills/discuss/SKILL.md" ]            && ok "discuss skill : present"    || err "discuss skill : missing"
    [ -f "$HOME/.claude/skills/pre-flight-capture/SKILL.md" ] && ok "pre-flight    : present"    || err "pre-flight    : missing"
    [ -f "$HOME/.claude/skills/write-changelog/SKILL.md" ]    && ok "changelog skill: present"   || err "changelog skill: missing"
    [ -f "$HOME/.claude/skills/mission-create/SKILL.md" ]     && ok "mission-create : present"    || err "mission-create : missing"
    [ -f "$HOME/.claude/skills/mission-snapshot/SKILL.md" ]   && ok "mission-snap.  : present"    || err "mission-snap.  : missing"
    [ -f "$HOME/.claude/skills/mission-continue/SKILL.md" ]   && ok "mission-cont.  : present"    || err "mission-cont.  : missing"
    [ -x "$HOME/.local/bin/paperflow-target" ]                && ok "target helper : executable" || err "target helper : missing"
    [ -x "$HOME/.local/bin/paperflow-continue" ]              && ok "continue laun. : executable" || err "continue laun. : missing"
    jq -e '.hooks.UserPromptSubmit' "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings UPS  : wired"      || err "settings UPS  : broken"
    jq -e '.hooks.PostToolUse'      "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings PTU  : wired"      || err "settings PTU  : broken"
}

echo
log "Activate hooks in any running Claude Code session:"
echo "  Open /hooks once (or restart) — running sessions don't auto-pick-up new hooks."
echo
log "Done. Try writing a spec — it'll auto-open with action buttons."
