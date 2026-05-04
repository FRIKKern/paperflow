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

# npm global write access — the #1 install failure on macOS. Homebrew puts
# node at /usr/local/bin and root-owns /usr/local/lib/node_modules, so a
# later `npm install -g` exits with EACCES and the user is left guessing
# (especially if we suppressed stderr). Catch it now with a clear remedy.
if command -v npm >/dev/null 2>&1; then
    NPM_PREFIX="$(npm config get prefix 2>/dev/null || true)"
    NPM_GLOBAL_DIR="$NPM_PREFIX/lib/node_modules"
    if [ -n "$NPM_PREFIX" ] && [ ! -w "$NPM_PREFIX/lib" ] 2>/dev/null && [ ! -w "$NPM_GLOBAL_DIR" ] 2>/dev/null; then
        err "npm cannot write to: $NPM_GLOBAL_DIR"
        printf '\n    paperflow installs live-server + mermaid as global npm packages.\n'
        printf '    Pick one fix and re-run:\n\n'
        printf '    A)  Reclaim ownership of the npm global dirs (one-time):\n'
        printf '        sudo chown -R $(whoami) %s/lib/node_modules %s/bin %s/share\n\n' "$NPM_PREFIX" "$NPM_PREFIX" "$NPM_PREFIX"
        printf '    B)  Use a user-local prefix:\n'
        printf '        npm config set prefix ~/.npm-global\n'
        printf '        export PATH="$HOME/.npm-global/bin:$PATH"   # add to ~/.zshrc\n\n'
        printf '    Then:  bash install.sh\n'
        exit 1
    fi
fi

# Optional: unlighthouse for site-audit (Phase 1c). Don't auto-install.
if command -v unlighthouse >/dev/null 2>&1; then
    skip "unlighthouse: present (site-audit ready)"
else
    skip "unlighthouse: not installed — site-audit needs: npm install -g @unlighthouse/cli puppeteer"
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
         "$HOME/docs/superpowers/audits" \
         "$HOME/docs/superpowers/audits/_archive" \
         "$HOME/docs/superpowers/_lib" \
         "$HOME/.paperflow" \
         "$HOME/.local/bin" \
         "$HOME/.local/log" \
         "$HOME/.openclaw/logs" \
         "$HOME/.claude/hooks" \
         "$HOME/.claude/skills/grill-plan" \
         "$HOME/.claude/skills/paperflow-install" \
         "$HOME/.claude/skills/discuss" \
         "$HOME/.claude/skills/pre-flight-capture" \
         "$HOME/.claude/skills/write-changelog" \
         "$HOME/.claude/skills/mission-create" \
         "$HOME/.claude/skills/mission-snapshot" \
         "$HOME/.claude/skills/mission-continue" \
         "$HOME/.claude/skills/paperflow-review-doc" \
         "$HOME/.claude/skills/site-audit" \
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
# Pinned to 1.2.2 — the last release before the 2024 maintainer change;
# newer pre-release builds have a known WebSocket-init regression that
# breaks our live-render WS-intercept.
log "live-server"
LIVE_SERVER_PIN="1.2.2"
LIVE_SERVER="$NODE_BIN_DIR/live-server"
if [ -x "$LIVE_SERVER" ]; then
    LS_VER="$("$LIVE_SERVER" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    if [ -n "$LS_VER" ] && [ "$LS_VER" != "$LIVE_SERVER_PIN" ]; then
        skip "already installed (v$LS_VER) — note: paperflow targets v$LIVE_SERVER_PIN; if you hit live-reload issues, run: npm uninstall -g live-server && bash install.sh"
    else
        skip "already installed (v${LS_VER:-unknown})"
    fi
else
    "$NODE_BIN_DIR/npm" install -g live-server@1.2.2 >/dev/null
    ok "installed (v$LIVE_SERVER_PIN)"
fi

# mermaid (npm global) — used by paperflow-validate to statically check
# Mermaid blocks in doc HTMLs before the user opens them in browser.
log "mermaid"
MERMAID_DIR="$NODE_BIN_DIR/../lib/node_modules/mermaid"
if [ -d "$MERMAID_DIR" ]; then
    MM_VER="$(/usr/bin/env node -e "console.log(require('$MERMAID_DIR/package.json').version)" 2>/dev/null || echo unknown)"
    skip "already installed (v$MM_VER)"
else
    "$NODE_BIN_DIR/npm" install -g mermaid >/dev/null
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

# Poll an http port until it responds 200, or timeout. Default 5s @ 0.5s steps.
wait_for_port() {
    local port="$1" max_tries="${2:-10}" tries=0
    while [ "$tries" -lt "$max_tries" ]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/" 2>/dev/null | grep -q 200; then
            return 0
        fi
        sleep 0.5
        tries=$((tries + 1))
    done
    return 1
}

# Wait for a LaunchAgent's port; if it's still down, kickstart once and re-poll.
ensure_agent_up() {
    local label="$1" port="$2"
    wait_for_port "$port" && return 0
    launchctl kickstart -k "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    wait_for_port "$port"
}

# ─── 4. live-server LaunchAgent ─────────────────────────────────────
log "LaunchAgent: $LR_LABEL"
LR_PLIST="$HOME/Library/LaunchAgents/$LR_LABEL.plist"
render "$REPO/launchagents/docs-livereload.plist.tmpl" "$LR_PLIST" "$LR_LABEL"
reload_agent "$LR_LABEL" "$LR_PLIST"
if ensure_agent_up "$LR_LABEL" 8765; then
    ok "up at http://localhost:8765"
else
    err "not reachable — check $HOME/.local/log/docs-livereload.err.log"
fi

# ─── 5. claude-bridge ───────────────────────────────────────────────
# On cmux.app systems we cannot run the bridge as a LaunchAgent: cmux's socket
# is in access_mode "cmuxOnly" and rejects connections whose responsible-process
# ancestor is launchd, returning "Failed to write to socket (Broken pipe)" on
# every dispatch. The bridge MUST be a child of cmux.app to inherit the trust
# cmux's auth requires. We achieve that with `cmux new-workspace --command`,
# which spawns the bridge as a managed cmux subprocess.
#
# On non-cmux systems (Apple Terminal / iTerm / plain Ghostty), keep the
# LaunchAgent path — same behavior as before.
if [ -n "${CMUX_SOCKET:-}" ] && [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ] && [ -x "$CMUX_BUNDLED_CLI_PATH" ]; then
    log "claude-bridge (cmux mode)"
    # Tear down any existing LaunchAgent — it would race for port 8766 and
    # always lose the cmux dispatch even if the port-bind succeeded.
    if launchctl print "gui/$(id -u)/$BR_LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$BR_LABEL" >/dev/null 2>&1 || true
        skip "removed legacy LaunchAgent (cmux requires in-app spawn)"
    fi
    if pgrep -f "node.*claude-bridge\.js" >/dev/null 2>&1; then
        skip "already running"
    else
        "$CMUX_BUNDLED_CLI_PATH" new-workspace \
            --name "paperflow-bridge" \
            --command "$NODE_BIN $REPO/bin/claude-bridge.js" \
            >/dev/null 2>&1 \
                && ok "spawned via cmux new-workspace" \
                || err "cmux new-workspace failed"
    fi
    if wait_for_port 8766 20; then
        ok "up at http://localhost:8766"
    else
        err "not reachable — check the paperflow-bridge workspace in cmux"
    fi
else
    log "LaunchAgent: $BR_LABEL"
    BR_PLIST="$HOME/Library/LaunchAgents/$BR_LABEL.plist"
    render "$REPO/launchagents/claude-bridge.plist.tmpl" "$BR_PLIST" "$BR_LABEL"
    reload_agent "$BR_LABEL" "$BR_PLIST"
    if ensure_agent_up "$BR_LABEL" 8766; then
        ok "up at http://localhost:8766"
    else
        err "not reachable — check $HOME/.local/log/claude-bridge.err.log"
    fi
fi

# ─── 6. Shared renderers in ~/docs/superpowers/_lib/ ────────────────
log "Renderers"
for f in doc.css doc.js grill.css grill.js mermaid-zoom.css mermaid-zoom.js live-render.css live-render.js; do
    cp "$REPO/lib/$f" "$HOME/docs/superpowers/_lib/$f"
    ok "$f"
done

# ─── 7. Hooks ───────────────────────────────────────────────────────
log "Hooks"
for f in inject-principles.sh auto-open-doc.sh validate-paperflow-doc.sh; do
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
    skip "PostToolUse auto-open hook already present"
else
    TMP="$(mktemp)"
    jq '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
        matcher: "Write|Edit",
        hooks: [{ type: "command",
                  command: "$HOME/.claude/hooks/auto-open-doc.sh",
                  timeout: 3 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged PostToolUse auto-open"
fi

if jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command? | type == "string" and endswith("validate-paperflow-doc.sh"))' "$SETTINGS" >/dev/null 2>&1; then
    skip "PostToolUse validate hook already present"
else
    TMP="$(mktemp)"
    jq '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
        matcher: "Write|Edit",
        hooks: [{ type: "command",
                  command: "$HOME/.claude/hooks/validate-paperflow-doc.sh",
                  timeout: 15 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged PostToolUse validate"
fi

# ─── 9. Skills ──────────────────────────────────────────────────────
log "Skills"
for s in grill-plan paperflow-install discuss pre-flight-capture write-changelog mission-create mission-snapshot mission-continue paperflow-review-doc site-audit; do
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

# ─── 10c. doc validator at ~/.local/bin/paperflow-validate ─────────
log "Helper: paperflow-validate"
cp "$REPO/bin/paperflow-validate" "$HOME/.local/bin/paperflow-validate"
chmod +x "$HOME/.local/bin/paperflow-validate"
ok "installed at ~/.local/bin/paperflow-validate"

# ─── 10d. audit wrapper at ~/.local/bin/paperflow-audit-site ───────
log "Helper: paperflow-audit-site"
cp "$REPO/bin/paperflow-audit-site" "$HOME/.local/bin/paperflow-audit-site"
chmod +x "$HOME/.local/bin/paperflow-audit-site"
ok "installed at ~/.local/bin/paperflow-audit-site"

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
    if ensure_agent_up "$LR_LABEL" 8765; then
        ok "live-server   : up    (http://localhost:8765)"
    else
        err "live-server   : DOWN"
    fi
    # In cmux mode the bridge isn't a LaunchAgent, so just probe the port.
    if [ -n "${CMUX_SOCKET:-}" ]; then
        if wait_for_port 8766 4; then
            ok "claude-bridge : up    (http://localhost:8766, cmux mode)"
        else
            err "claude-bridge : DOWN  (open the paperflow-bridge cmux workspace)"
        fi
    else
        if ensure_agent_up "$BR_LABEL" 8766; then
            ok "claude-bridge : up    (http://localhost:8766)"
        else
            err "claude-bridge : DOWN"
        fi
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
    [ -f "$HOME/.claude/skills/paperflow-review-doc/SKILL.md" ] && ok "review skill  : present"    || err "review skill  : missing"
    [ -f "$HOME/.claude/skills/site-audit/SKILL.md" ]         && ok "site-audit skill: present"   || err "site-audit skill: missing"
    [ -d "$HOME/docs/superpowers/audits" ]                    && ok "audits dir    : ready"      || err "audits dir    : missing"
    [ -x "$HOME/.claude/hooks/validate-paperflow-doc.sh" ]    && ok "validate hook : executable" || err "validate hook : missing"
    [ -x "$HOME/.local/bin/paperflow-target" ]                && ok "target helper : executable" || err "target helper : missing"
    [ -x "$HOME/.local/bin/paperflow-continue" ]              && ok "continue laun. : executable" || err "continue laun. : missing"
    [ -x "$HOME/.local/bin/paperflow-validate" ]              && ok "validator     : executable" || err "validator     : missing"
    [ -x "$HOME/.local/bin/paperflow-audit-site" ]            && ok "audit wrapper : executable" || err "audit wrapper : missing"
    jq -e '.hooks.UserPromptSubmit' "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings UPS  : wired"      || err "settings UPS  : broken"
    jq -e '.hooks.PostToolUse'      "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings PTU  : wired"      || err "settings PTU  : broken"
}

echo
printf '\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '⚠  RESTART CLAUDE CODE  before testing.\n'
printf '   Already-running sessions do NOT pick up the newly installed:\n'
printf '     • hooks         (run /hooks to reload without restarting)\n'
printf '     • skills        (grill-plan, discuss, mission-*, etc. — restart only)\n'
printf '     • CLAUDE.md     (loaded once at session start)\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n\n'
log "Done. Try writing a spec — it'll auto-open with action buttons."
