#!/usr/bin/env bash
# paperflow installer — idempotent. Safe to re-run.
#
# Installs the full doc-workflow stack:
#   - live-server LaunchAgent (~/docs hot reload, port 8765)
#   - claude-bridge LaunchAgent (browser → terminal, port 8766)
#   - shared web renderers in ~/docs/paperflow/_lib/
#   - Claude Code hooks (inject-principles, auto-open-doc)
#   - six paperflow-* skills at ~/.claude/skills/paperflow-{goal,plan,build,review,install,resume}/
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

# Beads (bd) — required for paperflow's task layer
if ! command -v bd >/dev/null 2>&1; then
    err "bd (Beads) is required. paperflow uses Beads as the system of record"
    err "for goals + phases + tasks. Pick one and re-run:"
    printf '\n      brew install beads        (macOS Homebrew)\n'
    printf '      npm i -g beads            (cross-platform)\n\n'
    printf '    See https://github.com/gastownhall/beads\n'
    exit 1
fi
ok "bd ($(bd --version 2>/dev/null | head -n1 || echo 'version unknown'))"

# Optional version baseline check — non-fatal warning only.
# Known-good baseline: 1.0.3. Below that, bd may not have all paperflow's verbs.
BD_VERSION="$(bd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo '0.0.0')"
BD_BASELINE="1.0.3"
if [ "$(printf '%s\n%s\n' "$BD_VERSION" "$BD_BASELINE" | sort -V | head -n1)" != "$BD_BASELINE" ]; then
    skip "bd $BD_VERSION is below paperflow's baseline $BD_BASELINE — some verbs may differ"
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

# Optional: unlighthouse for paperflow-review's site-audit sub-flow. Don't auto-install.
if command -v unlighthouse >/dev/null 2>&1; then
    skip "unlighthouse: present (site audits ready via paperflow-review)"
else
    skip "unlighthouse: not installed — site audits in paperflow-review need: npm install -g @unlighthouse/cli puppeteer"
fi

ok "ready"

# ─── 0b. Migration: superpowers → paperflow paths ──────────────────
# Idempotent. v1 layout (real ~/docs/superpowers/) gets moved to
# ~/docs/paperflow/ and a backward-compat symlink is installed at
# ~/docs/superpowers → paperflow. Re-runs are no-ops once the v2
# layout is in place. Sets ~/.paperflow/.major-version=2.
log "Migration: superpowers → paperflow paths"
PF_DOCS="$HOME/docs/paperflow"
SP_DOCS="$HOME/docs/superpowers"

mkdir -p "$HOME/docs"

# Case A: legacy real dir at ~/docs/superpowers, no paperflow yet.
if [ -d "$SP_DOCS" ] && [ ! -L "$SP_DOCS" ] && [ ! -e "$PF_DOCS" ]; then
    mv "$SP_DOCS" "$PF_DOCS"
    ln -s paperflow "$SP_DOCS"
    ok "moved ~/docs/superpowers → ~/docs/paperflow + compat symlink"
# Case B: split brain — both real dir and paperflow exist. Bail loudly.
elif [ -d "$SP_DOCS" ] && [ ! -L "$SP_DOCS" ] && [ -d "$PF_DOCS" ]; then
    err "both ~/docs/superpowers (real dir) and ~/docs/paperflow exist."
    err "resolve manually before re-running install.sh."
    exit 2
# Case C: paperflow exists, symlink missing. Recreate symlink.
elif [ -d "$PF_DOCS" ] && [ ! -e "$SP_DOCS" ]; then
    ln -s paperflow "$SP_DOCS"
    ok "created compat symlink ~/docs/superpowers → paperflow"
# Case D: fresh install, neither exists. Create paperflow + symlink.
elif [ ! -e "$PF_DOCS" ] && [ ! -e "$SP_DOCS" ]; then
    mkdir -p "$PF_DOCS"
    ln -s paperflow "$SP_DOCS"
    ok "created fresh paperflow tree + compat symlink"
else
    skip "already paperflow"
fi

# Sed-rewrite paths inside any pre-existing user HTMLs. Narrow patterns —
# only the actual stylesheet/script and dir prefixes, not bare /superpowers/.
if [ -d "$PF_DOCS" ]; then
    find "$PF_DOCS" -name '*.html' -type f -exec \
        sed -i '' \
            -e 's|/superpowers/_lib/|/paperflow/_lib/|g' \
            -e 's|/superpowers/specs/|/paperflow/specs/|g' \
            -e 's|/superpowers/plans/|/paperflow/plans/|g' \
            -e 's|/superpowers/grills/|/paperflow/grills/|g' \
            -e 's|/superpowers/notes/|/paperflow/notes/|g' \
            -e 's|/superpowers/captures/|/paperflow/captures/|g' \
            -e 's|/superpowers/changelog/|/paperflow/changelog/|g' \
            -e 's|/superpowers/missions/|/paperflow/missions/|g' \
            -e 's|/superpowers/audits/|/paperflow/audits/|g' \
            -e 's|~/docs/superpowers/|~/docs/paperflow/|g' \
            {} + 2>/dev/null || true
fi

# Write the version flag (paperflow v2).
mkdir -p "$HOME/.paperflow"
echo 2 > "$HOME/.paperflow/.major-version"
ok "version flag set to 2 (~/.paperflow/.major-version)"

# ─── 1. Directories ────────────────────────────────────────────────
log "Directories"
mkdir -p "$HOME/docs/paperflow/specs" \
         "$HOME/docs/paperflow/plans" \
         "$HOME/docs/paperflow/grills" \
         "$HOME/docs/paperflow/notes" \
         "$HOME/docs/paperflow/captures" \
         "$HOME/docs/paperflow/changelog" \
         "$HOME/docs/paperflow/missions" \
         "$HOME/docs/paperflow/audits" \
         "$HOME/docs/paperflow/audits/_archive" \
         "$HOME/docs/paperflow/_lib" \
         "$HOME/.paperflow" \
         "$HOME/.local/bin" \
         "$HOME/.local/log" \
         "$HOME/.openclaw/logs" \
         "$HOME/.claude/hooks" \
         "$HOME/.claude/skills/paperflow-goal" \
         "$HOME/.claude/skills/paperflow-plan" \
         "$HOME/.claude/skills/paperflow-build" \
         "$HOME/.claude/skills/paperflow-review" \
         "$HOME/.claude/skills/paperflow-install" \
         "$HOME/.claude/skills/paperflow-resume" \
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

# ─── 6. Shared renderers in ~/docs/paperflow/_lib/ ──────────────────
log "Renderers"
for f in doc.css doc.js grill.css grill.js mermaid-zoom.css mermaid-zoom.js live-render.css live-render.js; do
    cp "$REPO/lib/$f" "$HOME/docs/paperflow/_lib/$f"
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
for s in paperflow-goal paperflow-plan paperflow-build paperflow-review paperflow-install paperflow-resume; do
    if [ -f "$REPO/skills/$s/SKILL.md" ]; then
        mkdir -p "$HOME/.claude/skills/$s"
        cp "$REPO/skills/$s/SKILL.md" "$HOME/.claude/skills/$s/SKILL.md"
        ok "$s"
    else
        err "$s : missing template"
    fi
done

# ─── 9b. Statusline ────────────────────────────────────────────────
# One bash script + one editable JSON, wired into ~/.claude/settings.json.
# Sidecar SHA tracking — overwrite only when the live file matches the SHA we
# recorded the last time we installed it. User-edited files are left alone.
log "Statusline"

install_statusline_script() {
    local src="$REPO/lib/statusline.sh"
    local dst="$HOME/.claude/statusline.sh"
    local sidecar="$HOME/.paperflow/.statusline-installed-sha"
    mkdir -p "$HOME/.claude" "$HOME/.paperflow"
    if [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        chmod +x "$dst"
        shasum -a 256 "$dst" | cut -d' ' -f1 > "$sidecar"
        ok "installed $dst"
        return
    fi
    if [ ! -f "$sidecar" ]; then
        skip "$dst — no install sidecar (delete file to overwrite)"
        return
    fi
    local live recorded
    live=$(shasum -a 256 "$dst" | cut -d' ' -f1)
    recorded=$(cat "$sidecar")
    if [ "$live" = "$recorded" ]; then
        cp "$src" "$dst"
        chmod +x "$dst"
        shasum -a 256 "$dst" | cut -d' ' -f1 > "$sidecar"
        ok "upgraded $dst"
    else
        skip "$dst — your statusline differs from the last paperflow install"
        printf '              rename it or delete %s to overwrite\n' "$sidecar"
    fi
}

install_statusline_limits() {
    local src="$REPO/lib/statusline-limits.json"
    local dst="$HOME/.paperflow/statusline-limits.json"
    local sidecar="$HOME/.paperflow/.statusline-limits-installed-sha"
    mkdir -p "$HOME/.paperflow"
    if [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        shasum -a 256 "$dst" | cut -d' ' -f1 > "$sidecar"
        ok "installed $dst"
        return
    fi
    if [ ! -f "$sidecar" ]; then
        skip "$dst — no install sidecar (delete file to overwrite)"
        return
    fi
    local live recorded
    live=$(shasum -a 256 "$dst" | cut -d' ' -f1)
    recorded=$(cat "$sidecar")
    if [ "$live" = "$recorded" ]; then
        cp "$src" "$dst"
        shasum -a 256 "$dst" | cut -d' ' -f1 > "$sidecar"
        ok "upgraded $dst"
    else
        skip "$dst — user-edited limits"
        printf '              delete %s to overwrite\n' "$sidecar"
    fi
}

merge_statusline_settings() {
    local target='$HOME/.claude/statusline.sh'
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    local existing
    existing=$(jq -r '.statusLine.command // empty' "$SETTINGS")
    if [ -z "$existing" ]; then
        local tmp; tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
        jq --arg cmd "$target" \
           '.statusLine = { "type": "command", "command": $cmd }' \
           "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
        trap - EXIT
        ok "merged statusLine into $SETTINGS"
    elif [ "$existing" = "$target" ]; then
        skip "statusLine already points at paperflow"
    else
        skip "settings.json — your statusLine points at $existing"
        printf '              Not overwriting. To switch:\n\n'
        printf '    jq '"'"'.statusLine.command = "$HOME/.claude/statusline.sh"'"'"' \\\n'
        printf '       ~/.claude/settings.json | sponge ~/.claude/settings.json\n\n'
    fi
}

install_statusline_script
install_statusline_limits
merge_statusline_settings

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

# ─── 10e. Beads bootstrap helper ───────────────────────────────────
log "Helper: paperflow-bd-init"
cp "$REPO/bin/paperflow-bd-init" "$HOME/.local/bin/paperflow-bd-init"
chmod +x "$HOME/.local/bin/paperflow-bd-init"
ok "installed at ~/.local/bin/paperflow-bd-init"

# ─── 10f. Legacy goals migration helper ────────────────────────────
log "Helper: paperflow-migrate-legacy-goals"
cp "$REPO/bin/paperflow-migrate-legacy-goals" "$HOME/.local/bin/paperflow-migrate-legacy-goals"
chmod +x "$HOME/.local/bin/paperflow-migrate-legacy-goals"
ok "installed at ~/.local/bin/paperflow-migrate-legacy-goals"

# ─── 10g. Migration: legacy goals → Beads ──────────────────────────
log "Migration: legacy goals → Beads"
if "$HOME/.local/bin/paperflow-migrate-legacy-goals"; then
    ok "migration complete"
else
    err "migration failed — check stderr above; legacy files preserved untouched"
fi

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
    [ -f "$HOME/docs/paperflow/_lib/doc.js" ]          && ok "doc renderer  : present"    || err "doc renderer  : missing"
    [ -f "$HOME/docs/paperflow/_lib/grill.js" ]        && ok "grill render. : present"    || err "grill render. : missing"
    [ -f "$HOME/.claude/skills/paperflow-goal/SKILL.md" ]     && ok "goal skill    : present"    || err "goal skill    : missing"
    [ -f "$HOME/.claude/skills/paperflow-plan/SKILL.md" ]     && ok "plan skill    : present"    || err "plan skill    : missing"
    [ -f "$HOME/.claude/skills/paperflow-build/SKILL.md" ]    && ok "build skill   : present"    || err "build skill   : missing"
    [ -f "$HOME/.claude/skills/paperflow-review/SKILL.md" ]   && ok "review skill  : present"    || err "review skill  : missing"
    [ -f "$HOME/.claude/skills/paperflow-install/SKILL.md" ]  && ok "install skill : present"    || err "install skill : missing"
    [ -f "$HOME/.claude/skills/paperflow-resume/SKILL.md" ]   && ok "resume skill  : present"    || err "resume skill  : missing"
    [ -d "$HOME/docs/paperflow/audits" ]                      && ok "audits dir    : ready"      || err "audits dir    : missing"
    [ -x "$HOME/.claude/hooks/validate-paperflow-doc.sh" ]    && ok "validate hook : executable" || err "validate hook : missing"
    [ -x "$HOME/.local/bin/paperflow-target" ]                && ok "target helper : executable" || err "target helper : missing"
    [ -x "$HOME/.local/bin/paperflow-continue" ]              && ok "continue laun. : executable" || err "continue laun. : missing"
    [ -x "$HOME/.local/bin/paperflow-validate" ]              && ok "validator     : executable" || err "validator     : missing"
    [ -x "$HOME/.local/bin/paperflow-audit-site" ]            && ok "audit wrapper : executable" || err "audit wrapper : missing"
    [ -x "$HOME/.local/bin/paperflow-bd-init" ]               && ok "bd-init helper : executable" || err "bd-init helper : missing"
    [ -x "$HOME/.local/bin/paperflow-migrate-legacy-goals" ]  && ok "migrate helper : executable" || err "migrate helper : missing"
    jq -e '.hooks.UserPromptSubmit' "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings UPS  : wired"      || err "settings UPS  : broken"
    jq -e '.hooks.PostToolUse'      "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings PTU  : wired"      || err "settings PTU  : broken"
    [ -x "$HOME/.claude/statusline.sh" ]                       && ok "statusline    : executable" || err "statusline    : missing"
    [ -f "$HOME/.paperflow/statusline-limits.json" ]           && ok "limits.json   : present"    || err "limits.json   : missing"
    [ -f "$HOME/.paperflow/.statusline-installed-sha" ]        && ok "sl sidecar    : present"    || err "sl sidecar    : missing"
    [ -f "$HOME/.paperflow/.statusline-limits-installed-sha" ] && ok "limits sidecar: present"    || err "limits sidecar: missing"
    jq -e '.statusLine' "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings stat.: wired"      || skip "settings stat.: not wired (foreign or absent)"
}

echo
printf '\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '⚠  RESTART CLAUDE CODE  before testing.\n'
printf '   Already-running sessions do NOT pick up the newly installed:\n'
printf '     • hooks         (run /hooks to reload without restarting)\n'
printf '     • skills        (paperflow-goal/plan/build/review/install/resume — restart only)\n'
printf '     • CLAUDE.md     (loaded once at session start)\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n\n'

# Running-Claude warning. The /claude space pattern avoids matching paperflow,
# claude-flow, etc. — only actual Claude Code sessions show up here.
warn_running_claude() {
    local n
    n=$(pgrep -f '/claude ' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    if [ "${n:-0}" -gt 0 ]; then
        printf '\033[1;33m⚠  Found %s running Claude Code session(s) — the statusline won'\''t appear in those until you restart them.\033[0m\n\n' "$n"
    fi
}
warn_running_claude

log "Done. Try writing a spec — it'll auto-open with action buttons."
