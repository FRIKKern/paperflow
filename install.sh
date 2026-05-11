#!/usr/bin/env bash
# paperflow installer — idempotent. Safe to re-run.
#
# Installs the full doc-workflow stack:
#   - live-server LaunchAgent (~/docs hot reload, port 8765)
#   - paperflow-aux LaunchAgent (auxiliary daemon, future host service)
#   - claude-bridge: per-instance, spawned by the SessionStart hook
#     (no LaunchAgent; one bridge per Claude Code session on port 8766)
#   - shared web renderers in ~/docs/paperflow/_lib/
#   - Claude Code hooks (inject-principles, auto-open-doc)
#   - six lifecycle skills at ~/.claude/skills/{goal,plan,build,review,install,resume}/
#     (plus the setup skill at ~/.claude/skills/setup/ and the
#      autopilot skill at ~/.claude/skills/autopilot/ — 8 total)
#   - terminal-target helper at ~/.local/bin/paperflow-target
#   - ~/.claude/CLAUDE.md (preamble refresh; user content outside the
#     <!-- paperflow:preamble:* --> sentinels is preserved)
#
# After install, open /hooks once in any running Claude Code session
# (or restart) so hooks are picked up.
#
# ── Flags ──────────────────────────────────────────────────────────
#   --with-openclaw       Append the OpenClaw delegation fragment to
#                         ~/.claude/CLAUDE.md. Verifies the binary
#                         exists at /opt/homebrew/bin/openclaw and
#                         warns (non-fatal) if missing. Does NOT
#                         install OpenClaw.
#   --with-browserbase    Append the BrowserBase fragment. No binary
#                         check — BrowserBase is a cloud API.
#   --with-unlighthouse   Append the Unlighthouse fragment. Offers to
#                         `npm i -g @unlighthouse/cli puppeteer` if
#                         not already on PATH (asks first).
#   --reset               Tarball ~/.claude/{CLAUDE.md, hooks, skills}
#                         and ~/.paperflow/ to
#                         ~/.paperflow/backups/<YYYY-MM-DD-HHMMSS>.tar.gz,
#                         then DELETE those paths and re-run install
#                         fresh. Combine with --with-* flags to pick
#                         the integration set for the new install.
#   --reset-dock          Overwrite an existing
#                         ${XDG_CONFIG_HOME:-$HOME/.config}/cmux/dock.json
#                         with paperflow's rendered template (after
#                         backing up to dock.json.bak.<ts>). Without
#                         this flag, the install skips a pre-existing
#                         dock config and prints a status row.
#
# Default install (no flags) is lean: only the core paperflow CLAUDE.md
# is rendered — no integration prose for OpenClaw / BrowserBase /
# Unlighthouse unless explicitly opted in.

set -euo pipefail

# ── Flag parsing ───────────────────────────────────────────────────
WITH_OPENCLAW=0
WITH_BROWSERBASE=0
WITH_UNLIGHTHOUSE=0
DO_RESET=0
DO_RESET_DOCK=0
MERGE_CLAUDEMD=0
YES="${PAPERFLOW_YES:-0}"
for arg in "$@"; do
    case "$arg" in
        --with-openclaw)     WITH_OPENCLAW=1 ;;
        --with-browserbase)  WITH_BROWSERBASE=1 ;;
        --with-unlighthouse) WITH_UNLIGHTHOUSE=1 ;;
        --reset)             DO_RESET=1 ;;
        --reset-dock)        DO_RESET_DOCK=1 ;;
        --merge|--merge-claude-md) MERGE_CLAUDEMD=1 ;;
        --yes)               YES=1 ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown flag: %s\n' "$arg" >&2
            printf 'See --help for the supported flags.\n' >&2
            exit 1
            ;;
    esac
done

log()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[1;33m•\033[0m %s\n' "$*"; }
err()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; }

REPO="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(id -un)"

# ── Reset: tarball-backup + nuke before fresh install ──────────────
# Runs BEFORE everything else so the rest of install.sh sees a clean
# slate and the create-if-missing gate on CLAUDE.md fires fresh.
if [ "$DO_RESET" -eq 1 ]; then
    log "Reset"
    BACKUP_DIR="$HOME/.paperflow/backups"
    mkdir -p "$BACKUP_DIR"
    TS="$(date +%Y-%m-%d-%H%M%S)"
    BACKUP_FILE="$BACKUP_DIR/$TS.tar.gz"

    # Build a list of paths that actually exist; tar with --files-from
    # so a missing path doesn't abort the whole archive.
    BACKUP_LIST="$(mktemp)"
    for p in "$HOME/.claude/CLAUDE.md" "$HOME/.claude/hooks" "$HOME/.claude/skills" "$HOME/.paperflow"; do
        [ -e "$p" ] && printf '%s\n' "$p" >> "$BACKUP_LIST"
    done
    if [ -s "$BACKUP_LIST" ]; then
        # Use absolute paths in the archive so untar to / restores in place.
        tar -czf "$BACKUP_FILE" --files-from "$BACKUP_LIST" 2>/dev/null \
            && ok "backup → $BACKUP_FILE" \
            || err "backup failed — bailing before any deletions"
        if [ ! -f "$BACKUP_FILE" ]; then
            rm -f "$BACKUP_LIST"
            exit 2
        fi
    else
        skip "nothing to back up (no live state)"
    fi
    rm -f "$BACKUP_LIST"

    # Now delete the live state. Skip ~/.paperflow/backups so the
    # archive we just wrote survives.
    rm -f "$HOME/.claude/CLAUDE.md"
    rm -rf "$HOME/.claude/hooks" "$HOME/.claude/skills"
    if [ -d "$HOME/.paperflow" ]; then
        find "$HOME/.paperflow" -mindepth 1 -maxdepth 1 \
             ! -name backups -exec rm -rf {} + 2>/dev/null || true
    fi
    ok "wiped live state (CLAUDE.md, hooks, skills, .paperflow/*)"

    # Re-create the major-version flag (also written below by the
    # migration block, but having it here makes intent explicit).
    mkdir -p "$HOME/.paperflow"
    echo 2 > "$HOME/.paperflow/.major-version"
    ok "version flag re-set to 2"
fi

# Configurable — defaults are reasonable. Override before running:
#   LABEL_PREFIX=dev.youralias bash install.sh
LABEL_PREFIX="${LABEL_PREFIX:-dev.${USER_NAME}}"
LR_LABEL="${LABEL_PREFIX}.docs-livereload"
BR_LABEL="${LABEL_PREFIX}.claude-bridge"

# ─── 0. Pre-flight ─────────────────────────────────────────────────
log "Pre-flight"

# Prereqs (node22, jq, git) verified by quickstart.sh; bd verified there too as of 2026-05-07.
# Manual-run guard: when install.sh is invoked directly (not via quickstart), bd
# might still be missing — keep a tiny clear-message check so the failure mode
# is obvious instead of dying inside the migration block far below.
if ! command -v bd >/dev/null 2>&1; then
    err "bd (Beads) is required. paperflow uses Beads as the system of record"
    err "for goals + phases + tasks. Pick one and re-run:"
    printf '\n      brew install beads        (macOS Homebrew)\n'
    printf '      npm i -g beads            (cross-platform)\n\n'
    printf '    Or just run:  bash scripts/quickstart.sh   (auto-installs)\n'
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
#
# Skip the EACCES bail when nvm is managing node — npm prefix is per-version
# and user-owned under ~/.nvm/versions/, so global installs always work.
_NVM_NODE=0
if [ -n "${NVM_DIR:-}" ]; then _NVM_NODE=1; fi
if [ "$_NVM_NODE" -eq 0 ] && command -v node >/dev/null 2>&1; then
    case "$(command -v node)" in
        */.nvm/*) _NVM_NODE=1 ;;
    esac
fi
if [ "$_NVM_NODE" -eq 1 ]; then
    skip "npm prefix: nvm-managed node — user-owned, no chown needed"
elif command -v npm >/dev/null 2>&1; then
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
        printf '    C)  Switch to nvm (recommended):\n'
        printf '        brew install nvm && nvm install 22\n\n'
        printf '    Then:  bash install.sh\n'
        exit 1
    fi
fi

# Optional: unlighthouse for /paperflow:review's site-audit sub-flow. Don't auto-install.
if command -v unlighthouse >/dev/null 2>&1; then
    skip "unlighthouse: present (site audits ready via /paperflow:review)"
else
    skip "unlighthouse: not installed — site audits in /paperflow:review need: npm install -g @unlighthouse/cli puppeteer"
fi

# Integration flag pre-flight — non-fatal, just visibility.
if [ "$WITH_OPENCLAW" -eq 1 ]; then
    if [ -x /opt/homebrew/bin/openclaw ]; then
        ok "openclaw: present at /opt/homebrew/bin/openclaw"
    else
        skip "openclaw: --with-openclaw set but /opt/homebrew/bin/openclaw missing — fragment will still ship in CLAUDE.md"
    fi
fi
if [ "$WITH_BROWSERBASE" -eq 1 ]; then
    skip "browserbase: cloud API — fragment will ship in CLAUDE.md (set BROWSERBASE_API_KEY in your shell env)"
fi
if [ "$WITH_UNLIGHTHOUSE" -eq 1 ]; then
    if ! command -v unlighthouse >/dev/null 2>&1; then
        # --yes (or piped stdin) → auto-install without prompting.
        if [ "${YES:-0}" = 1 ] || [ ! -t 0 ]; then
            "$(command -v npm)" install -g @unlighthouse/cli puppeteer >/dev/null \
                && ok "unlighthouse installed (--yes)" \
                || skip "unlighthouse: install failed — fragment will still ship in CLAUDE.md"
        else
            printf '  unlighthouse not on PATH. Install @unlighthouse/cli + puppeteer globally now? (y/N) '
            read -r _ULH_ANSWER || _ULH_ANSWER=""
            case "$_ULH_ANSWER" in
                y|Y|yes|YES)
                    "$(command -v npm)" install -g @unlighthouse/cli puppeteer >/dev/null \
                        && ok "unlighthouse installed" \
                        || err "unlighthouse install failed — fragment will still ship"
                    ;;
                *) skip "unlighthouse: skipping install — fragment will still ship in CLAUDE.md" ;;
            esac
        fi
    fi
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
         "$HOME/docs/paperflow/questionnaires" \
         "$HOME/docs/paperflow/notes" \
         "$HOME/docs/paperflow/captures" \
         "$HOME/docs/paperflow/changelog" \
         "$HOME/docs/paperflow/missions" \
         "$HOME/docs/paperflow/audits" \
         "$HOME/docs/paperflow/audits/_archive" \
         "$HOME/docs/paperflow/_lib" \
         "$HOME/.paperflow" \
         "$HOME/.paperflow/events" \
         "$HOME/.local/bin" \
         "$HOME/.local/log" \
         "$HOME/.openclaw/logs" \
         "$HOME/.claude/hooks" \
         "$HOME/.claude/skills/goal" \
         "$HOME/.claude/skills/plan" \
         "$HOME/.claude/skills/build" \
         "$HOME/.claude/skills/review" \
         "$HOME/.claude/skills/install" \
         "$HOME/.claude/skills/resume" \
         "$HOME/.claude/skills/setup" \
         "$HOME/.claude/skills/autopilot" \
         "$HOME/Library/LaunchAgents"
ok "ready"

# One-time legacy cleanup — remove the old paperflow-prefixed skill folders
# now that the plugin migration uses short names. Idempotent: nothing to do
# on second run.
for s in paperflow-goal paperflow-plan paperflow-build paperflow-review paperflow-install paperflow-resume; do
    if [ -d "$HOME/.claude/skills/$s" ]; then
        rm -rf "$HOME/.claude/skills/$s"
        ok "removed legacy skill folder: $s"
    fi
done

# One-time legacy cleanup — bootstrap skill folder renamed to setup (Cut 3,
# 2026-05). Drop the old folder when the plugin is host-installed.
if [ -d "$HOME/.claude/skills/bootstrap" ]; then
    rm -rf "$HOME/.claude/skills/bootstrap"
    ok "removed legacy skill folder: bootstrap (renamed to setup)"
fi

# One-time legacy cleanup — paperflow-bd-init folded into paperflow-doctor
# --ensure-bd (Cut 2, 2026-05). Drop the deployed binary if present.
if [ -e "$HOME/.local/bin/paperflow-bd-init" ]; then
    rm -f "$HOME/.local/bin/paperflow-bd-init"
    ok "removed legacy binary: paperflow-bd-init (use: paperflow-doctor --ensure-bd)"
fi

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

# Copy a paperflow helper script from the repo into ~/.local/bin/<name>.
# Collapses the cp + chmod +x + log + ok pattern repeated across section 10.
# Usage: deploy_helper <name> [<src-basename-if-different>]
deploy_helper() {
    local name="$1" src="${2:-$1}"
    log "Helper: $name"
    cp "$REPO/bin/$src" "$HOME/.local/bin/$name"
    chmod +x "$HOME/.local/bin/$name"
    ok "installed at ~/.local/bin/$name"
}

# sed-substituting variant for placeholder helpers (preflight, doctor).
# Usage: deploy_helper_sed <name> <sed-args...>
deploy_helper_sed() {
    local name="$1"; shift
    log "Helper: $name"
    sed "$@" "$REPO/bin/$name" > "$HOME/.local/bin/$name"
    chmod +x "$HOME/.local/bin/$name"
    ok "installed at ~/.local/bin/$name"
}

# Status-table executable check. Both branches share the prefix; the
# trailing word ("executable" / "missing") is swapped so error rows read
# correctly. Pass the prefix via $2 (e.g. "open hook   ").
status_x() {
    local path="$1" prefix="$2"
    if [ -x "$path" ]; then ok "$prefix : executable"; else err "$prefix : missing"; fi
}
# Status-table file-exists check (label: "present" / "missing").
status_f() {
    local path="$1" prefix="$2"
    if [ -f "$path" ]; then ok "$prefix : present"; else err "$prefix : missing"; fi
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

# ─── 5. claude-bridge: legacy cleanup (per-instance bridge takes over) ─
# As of paperflow-22c the bridge is spawned per Claude Code session by the
# SessionStart hook (see ~/.local/bin/paperflow-bridge-spawn). Neither the
# singleton LaunchAgent nor the cmux paperflow-bridge workspace is needed
# anymore. Idempotent cleanup: bootout + remove the old plist if present,
# delete the cmux workspace if present. Safe on re-run.
log "claude-bridge: legacy cleanup"
BR_PLIST_LEGACY="$HOME/Library/LaunchAgents/$BR_LABEL.plist"
if launchctl print "gui/$(id -u)/$BR_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$BR_LABEL" >/dev/null 2>&1 || true
    ok "booted out legacy LaunchAgent $BR_LABEL"
else
    skip "legacy LaunchAgent $BR_LABEL not loaded"
fi
if [ -f "$BR_PLIST_LEGACY" ]; then
    rm -f "$BR_PLIST_LEGACY"
    ok "removed legacy plist $BR_PLIST_LEGACY"
else
    skip "legacy plist $BR_PLIST_LEGACY not present"
fi
if command -v cmux >/dev/null 2>&1 \
   || { [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ] && [ -x "$CMUX_BUNDLED_CLI_PATH" ]; }; then
    CMUX_CLI="${CMUX_BUNDLED_CLI_PATH:-$(command -v cmux)}"
    if "$CMUX_CLI" list 2>/dev/null | grep -q 'paperflow-bridge'; then
        "$CMUX_CLI" delete-workspace paperflow-bridge >/dev/null 2>&1 \
            && ok "deleted legacy cmux workspace paperflow-bridge" \
            || skip "cmux delete-workspace paperflow-bridge failed (verb may differ)"
    else
        skip "legacy cmux workspace paperflow-bridge not present"
    fi
else
    skip "cmux not installed — no workspace cleanup needed"
fi

# ─── 5b. paperflow-aux daemon (LaunchAgent) ────────────────────────
# One-per-host auxiliary daemon. Takes over the live-server role on 8765
# (replacement is staged in a separate task; this step ships the plist).
AUX_LABEL="${LABEL_PREFIX}.paperflow-aux"
log "LaunchAgent: $AUX_LABEL"
AUX_PLIST="$HOME/Library/LaunchAgents/$AUX_LABEL.plist"
render "$REPO/launchagents/paperflow-aux.plist.tmpl" "$AUX_PLIST" "$AUX_LABEL"
# Bootout first if already loaded so the freshly-rendered plist takes effect
# (kickstart -k re-execs the old plist; bootstrap of an already-loaded label
# is a no-op). Idempotent.
if launchctl print "gui/$(id -u)/$AUX_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$AUX_LABEL" >/dev/null 2>&1 || true
fi
launchctl bootstrap "gui/$(id -u)" "$AUX_PLIST" >/dev/null 2>&1 || true
ok "loaded $AUX_LABEL"

# ─── 6. Shared renderers in ~/docs/paperflow/_lib/ ──────────────────
log "Renderers"
for f in doc.css doc.js grill.css grill.js mermaid-zoom.css mermaid-zoom.js live-render.css live-render.js goal-path-rail.css goal-path-rail.js diff-modal.js text-diff.js simplify-button.js; do
    cp "$REPO/lib/$f" "$HOME/docs/paperflow/_lib/$f"
    ok "$f"
done

# ─── 7. Hooks ───────────────────────────────────────────────────────
log "Hooks"
for f in inject-principles.sh auto-open-doc.sh validate-paperflow-doc.sh event-on-save.sh; do
    cp "$REPO/hooks/$f" "$HOME/.claude/hooks/$f"
    chmod +x "$HOME/.claude/hooks/$f"
    ok "$f"
done

# ─── 8. settings.json merge ─────────────────────────────────────────
log "settings.json"
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Tightened dedup: match the EXACT command string we write, not endswith() —
# a stale entry pointing at /old/path/inject-principles.sh would otherwise
# satisfy endswith() and silently keep the wrong hook installed.
HOOK_INJECT='$HOME/.claude/hooks/inject-principles.sh'
HOOK_OPEN='$HOME/.claude/hooks/auto-open-doc.sh'
HOOK_VALIDATE='$HOME/.claude/hooks/validate-paperflow-doc.sh'
HOOK_EVENT='$HOME/.claude/hooks/event-on-save.sh'

if jq -e --arg cmd "$HOOK_INJECT" '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command? == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    skip "UserPromptSubmit hook already present"
else
    TMP="$(mktemp)"
    jq --arg cmd "$HOOK_INJECT" '.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{
        hooks: [{ type: "command",
                  command: $cmd,
                  timeout: 5 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged UserPromptSubmit"
fi

if jq -e --arg cmd "$HOOK_OPEN" '.hooks.PostToolUse[]?.hooks[]? | select(.command? == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    skip "PostToolUse auto-open hook already present"
else
    TMP="$(mktemp)"
    jq --arg cmd "$HOOK_OPEN" '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
        matcher: "Write|Edit",
        hooks: [{ type: "command",
                  command: $cmd,
                  timeout: 3 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged PostToolUse auto-open"
fi

if jq -e --arg cmd "$HOOK_VALIDATE" '.hooks.PostToolUse[]?.hooks[]? | select(.command? == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    skip "PostToolUse validate hook already present"
else
    TMP="$(mktemp)"
    jq --arg cmd "$HOOK_VALIDATE" '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
        matcher: "Write|Edit",
        hooks: [{ type: "command",
                  command: $cmd,
                  timeout: 15 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged PostToolUse validate"
fi

if jq -e --arg cmd "$HOOK_EVENT" '.hooks.PostToolUse[]?.hooks[]? | select(.command? == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    skip "PostToolUse event-on-save hook already present"
else
    TMP="$(mktemp)"
    jq --arg cmd "$HOOK_EVENT" '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
        matcher: "Write|Edit",
        hooks: [{ type: "command",
                  command: $cmd,
                  timeout: 5 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged PostToolUse event-on-save"
fi

# Per-instance bridge lifecycle (paperflow-22c). SessionStart forks a
# bridge owned by this Claude Code process; SessionEnd sends SIGTERM so
# the daemon writes a clean orphan event before exit (the owner-watch in
# claude-bridge.js would catch it within 5s anyway). Both are idempotent —
# the jq -e dedup matches on the exact command string we write.
HOOK_BRIDGE_SPAWN='$HOME/.local/bin/paperflow-bridge-spawn'
HOOK_BRIDGE_KILL='pkill -TERM -f "claude-bridge.js.*--session-id=${CLAUDE_SESSION_ID}" >/dev/null 2>&1 || true'

if jq -e --arg cmd "$HOOK_BRIDGE_SPAWN" '.hooks.SessionStart[]?.hooks[]? | select(.command? == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    skip "SessionStart bridge-spawn hook already present"
else
    TMP="$(mktemp)"
    jq --arg cmd "$HOOK_BRIDGE_SPAWN" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{
        hooks: [{ type: "command",
                  command: $cmd,
                  timeout: 5 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged SessionStart bridge-spawn"
fi

if jq -e --arg cmd "$HOOK_BRIDGE_KILL" '.hooks.SessionEnd[]?.hooks[]? | select(.command? == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    skip "SessionEnd bridge-kill hook already present"
else
    TMP="$(mktemp)"
    jq --arg cmd "$HOOK_BRIDGE_KILL" '.hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{
        hooks: [{ type: "command",
                  command: $cmd,
                  timeout: 3 }]
    }])' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    ok "merged SessionEnd bridge-kill"
fi

# ─── 8b. paperflow Dock (cmux) ──────────────────────────────────────
# Daemon + thin feed client + XDG-compliant dock.json. Skip-on-existing
# default; --reset-dock overwrites after backing up to .bak.<ts>.
log "paperflow Dock"

# (1) install daemon + feed client to ~/.local/bin/
cp "$REPO/bin/paperflow-dock-daemon" "$HOME/.local/bin/paperflow-dock-daemon"
chmod +x "$HOME/.local/bin/paperflow-dock-daemon"
ok "daemon → ~/.local/bin/paperflow-dock-daemon"

cp "$REPO/bin/paperflow-dock-feed" "$HOME/.local/bin/paperflow-dock-feed"
chmod +x "$HOME/.local/bin/paperflow-dock-feed"
ok "feed client → ~/.local/bin/paperflow-dock-feed"

# (2) render lib/dock.json.tmpl with __HOME__ substituted; resolve XDG path.
DOCK_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cmux"
DOCK_CONFIG_FILE="$DOCK_CONFIG_DIR/dock.json"
mkdir -p "$DOCK_CONFIG_DIR"

if [ -f "$DOCK_CONFIG_FILE" ] && [ "$DO_RESET_DOCK" -ne 1 ]; then
    skip "dock config exists at $DOCK_CONFIG_FILE — pass --reset-dock to overwrite"
else
    if [ -f "$DOCK_CONFIG_FILE" ] && [ "$DO_RESET_DOCK" -eq 1 ]; then
        DOCK_BACKUP="$DOCK_CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$DOCK_CONFIG_FILE" "$DOCK_BACKUP"
        ok "backup → $DOCK_BACKUP"
    fi
    render "$REPO/lib/dock.json.tmpl" "$DOCK_CONFIG_FILE" ""
    ok "wrote $DOCK_CONFIG_FILE"
fi

# (3) daemon liveness — only spawn if socket isn't responsive.
DOCK_SOCK="$HOME/.paperflow/dock.sock"
mkdir -p "$HOME/.paperflow"
DOCK_DAEMON_RUNNING=0
if [ -S "$DOCK_SOCK" ] \
   && printf 'active-context\n' | /usr/bin/nc -U -w 1 "$DOCK_SOCK" >/dev/null 2>&1; then
    skip "daemon already running (socket responsive)"
    DOCK_DAEMON_RUNNING=1
else
    if [ -S "$DOCK_SOCK" ]; then rm -f "$DOCK_SOCK" 2>/dev/null || true; fi
    if [ -n "${CMUX_SOCKET:-}" ] && [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ] && [ -x "$CMUX_BUNDLED_CLI_PATH" ]; then
        "$CMUX_BUNDLED_CLI_PATH" new-workspace \
            --name "paperflow-dock-daemon" \
            --command "$NODE_BIN $HOME/.local/bin/paperflow-dock-daemon" \
            >/dev/null 2>&1 \
                && ok "daemon spawned via cmux new-workspace" \
                || err "cmux new-workspace failed for paperflow-dock-daemon"
    else
        nohup "$NODE_BIN" "$HOME/.local/bin/paperflow-dock-daemon" \
            </dev/null >/tmp/paperflow-dock-daemon.log 2>&1 &
        disown
        ok "daemon spawned in background (non-cmux) → /tmp/paperflow-dock-daemon.log"
    fi
    # Brief wait for the socket to come up.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -S "$DOCK_SOCK" ] && DOCK_DAEMON_RUNNING=1 && break
        sleep 0.5
    done
    [ "$DOCK_DAEMON_RUNNING" -eq 1 ] || skip "daemon socket did not appear within 5 s — check the spawn"
fi

# ─── 8e. Plugin presence check (skill ownership resolver) ──────────
# When the paperflow plugin is installed via /plugin install, the plugin
# owns the skill registrations (/paperflow:goal etc.). Duplicating them
# in ~/.claude/skills/ creates ambiguous slash commands — Claude has to
# guess between /goal (host) and /paperflow:goal (plugin). Plugin wins:
# sweep any leftover host skills, skip the host copy step.
PAPERFLOW_PLUGIN_INSTALLED=0
if [ -d "$HOME/.claude/plugins/cache" ] \
   && find "$HOME/.claude/plugins/cache" -path '*/paperflow/*/.claude-plugin/plugin.json' \
        2>/dev/null | head -1 | grep -q .; then
    PAPERFLOW_PLUGIN_INSTALLED=1
    log "Plugin detected — host skill copy + threshold refresh will be skipped"
    for s in goal plan build review install resume setup autopilot; do
        if [ -d "$HOME/.claude/skills/$s" ]; then
            rm -rf "$HOME/.claude/skills/$s"
            ok "swept duplicate host skill: $s (plugin owns /paperflow:$s)"
        fi
    done
fi

# ─── 9. Skills ──────────────────────────────────────────────────────
log "Skills"
if [ "$PAPERFLOW_PLUGIN_INSTALLED" = "1" ]; then
    skip "provided by plugin — host copy skipped (slashes: /paperflow:goal etc.)"
else
    for s in goal plan build review install resume setup autopilot; do
        if [ -f "$REPO/skills/$s/SKILL.md" ]; then
            mkdir -p "$HOME/.claude/skills/$s"
            cp "$REPO/skills/$s/SKILL.md" "$HOME/.claude/skills/$s/SKILL.md"
            ok "$s"
        else
            err "$s : missing template"
        fi
    done
fi

# ─── 9a. Refresh threshold blocks ──────────────────────────────────
# Splice lib/shared-thresholds.md between the BEGIN/END sentinels in
# each non-exempt skill body. Idempotent — running twice produces no
# diff. The resume skill is exempt (read-only on Beads). Skipped when
# plugin owns the skills — those SKILL.md files are versioned with the
# plugin and refresh via /plugin update, not install.sh.
log "Refresh threshold blocks"
if [ "$PAPERFLOW_PLUGIN_INSTALLED" = "1" ]; then
    skip "skipped — plugin owns SKILL.md content (refresh via /plugin update)"
    SKIP_THRESHOLD_REFRESH=1
fi
SHARED="$REPO/lib/shared-thresholds.md"
SKILLS_DIR="$HOME/.claude/skills"
NON_EXEMPT="goal plan build review install autopilot"
if [ "${SKIP_THRESHOLD_REFRESH:-0}" = "1" ]; then
    :
elif [ ! -f "$SHARED" ]; then
    err "missing source: $SHARED"
else
    for s in $NON_EXEMPT; do
        SKILL_FILE="$SKILLS_DIR/$s/SKILL.md"
        [ -f "$SKILL_FILE" ] || { skip "$s — SKILL.md not installed"; continue; }
        if ! grep -q '<!-- BEGIN paperflow-thresholds -->' "$SKILL_FILE"; then
            skip "$s — no BEGIN sentinel (block not declared in this skill)"
            continue
        fi
        TMP="$(mktemp)"
        trap 'rm -f "$TMP"' EXIT
        # Anchor sentinel matches to lines whose ONLY content is the
        # sentinel — otherwise prose that mentions the marker (as in
        # the install skill's "Refreshing the threshold block" subsection)
        # falsely triggers the splice and truncates the file.
        awk -v shared="$SHARED" '
          /^<!-- BEGIN paperflow-thresholds -->$/ {
              print
              while ((getline line < shared) > 0) print line
              close(shared)
              skip = 1
              next
          }
          /^<!-- END paperflow-thresholds -->$/ {
              skip = 0
              print
              next
          }
          !skip { print }
        ' "$SKILL_FILE" > "$TMP" && mv "$TMP" "$SKILL_FILE"
        trap - EXIT
        ok "refreshed $s"
    done
fi

# ─── 9a1. Refresh Step 0 + Step 0.5 stanzas ───────────────────────
# Same splice mechanism as 9a, pointing at lib/shared-step-0.md and
# lib/shared-step-0.5.md. Step 0 lives in 7 skills (every skill that
# can be invoked directly); Step 0.5 lives only in the 3 doc-writing
# skills (goal/plan/review) — install.sh and autopilot carry local
# variants that are not refreshed. Skipped when the plugin owns the
# files (refresh via /plugin update).
log "Refresh Step 0 / Step 0.5 stanzas"
if [ "${SKIP_THRESHOLD_REFRESH:-0}" = "1" ]; then
    skip "skipped — plugin owns SKILL.md content (refresh via /plugin update)"
else
    splice_block() {
        local skill_file="$1" begin="$2" end="$3" source="$4"
        [ -f "$source" ] || { err "missing source: $source"; return 1; }
        grep -q "$begin" "$skill_file" || return 0
        local tmp
        tmp="$(mktemp)"
        awk -v shared="$source" -v begin="$begin" -v end="$end" '
          $0 == begin {
              print
              while ((getline line < shared) > 0) print line
              close(shared)
              skip = 1
              next
          }
          $0 == end {
              skip = 0
              print
              next
          }
          !skip { print }
        ' "$skill_file" > "$tmp" && mv "$tmp" "$skill_file"
    }
    SHARED_S0="$REPO/lib/shared-step-0.md"
    SHARED_S05="$REPO/lib/shared-step-0.5.md"
    STEP0_SKILLS="goal plan build review install autopilot resume"
    STEP05_SKILLS="goal plan review"
    for s in $STEP0_SKILLS; do
        SKILL_FILE="$SKILLS_DIR/$s/SKILL.md"
        [ -f "$SKILL_FILE" ] || { skip "$s — SKILL.md not installed"; continue; }
        if splice_block "$SKILL_FILE" \
                        '<!-- BEGIN paperflow-step-0 -->' \
                        '<!-- END paperflow-step-0 -->' \
                        "$SHARED_S0"; then
            ok "step-0: refreshed $s"
        fi
    done
    for s in $STEP05_SKILLS; do
        SKILL_FILE="$SKILLS_DIR/$s/SKILL.md"
        [ -f "$SKILL_FILE" ] || { skip "$s — SKILL.md not installed"; continue; }
        if splice_block "$SKILL_FILE" \
                        '<!-- BEGIN paperflow-step-0.5 -->' \
                        '<!-- END paperflow-step-0.5 -->' \
                        "$SHARED_S05"; then
            ok "step-0.5: refreshed $s"
        fi
    done
fi

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

# ─── 10. Helper deployments to ~/.local/bin ────────────────────────
# Every helper goes through deploy_helper (or deploy_helper_sed for the
# two that need __VAR__ substitution). Order is preserved from the
# legacy per-helper sections (10, 10b, 10c, 10d, 10e1/2/3, 10f, 10f0,
# 10i, 10h, 10f1, 10f2, 10f3) — `paperflow-doctor` must land before the
# migration step in 10g, which it precedes.

deploy_helper paperflow-target          get-terminal-target.sh
deploy_helper paperflow-aux-daemon
deploy_helper paperflow-continue
deploy_helper paperflow-validate
deploy_helper paperflow-audit-site

# Sed-substituting helpers — runtime preflight + health doctor templates.
deploy_helper_sed paperflow-preflight \
    -e "s|__NODE_BIN__|$NODE_BIN|g" \
    -e "s|__BRIDGE_JS__|$REPO/bin/claude-bridge.js|g"
deploy_helper_sed paperflow-doctor \
    -e "s|__REPO__|$REPO|g" \
    -e "s|__NODE_BIN__|$NODE_BIN|g"

deploy_helper paperflow-doc-meta
deploy_helper paperflow-migrate-legacy-goals
deploy_helper paperflow-goal-merge
deploy_helper paperflow-claim-files
deploy_helper pf
deploy_helper paperflow-active-scope
deploy_helper paperflow-audit-orchestrator-budget
deploy_helper paperflow-backfill-goal-id

# Per-instance bridge spawn wrapper (paperflow-22c). The wrapper resolves
# claude-bridge.js via `dirname "$0"`, so we co-install both under
# ~/.local/bin/ — that makes the lookup work both in-repo (where they sit
# side-by-side in bin/) and post-install (where they sit side-by-side here).
deploy_helper paperflow-bridge-spawn
deploy_helper claude-bridge.js

# ─── 10g0. Beads aliases — hide kind:event from default `bd list/ready` ──
# Sidecar-driven event-tasks (paperflow-e5v) are noise in daily ops. Append
# two alias blocks to ~/.beads/aliases.toml so `bd list` and `bd ready` filter
# them out by default. Idempotent — only writes when the exact block isn't
# already present. Override per-call with `bd list --no-default-args` (or
# explicitly `bd list --label kind:event` to view them).
log "Beads aliases: filter kind:event"
BD_ALIASES="$HOME/.beads/aliases.toml"
mkdir -p "$HOME/.beads"
[ -f "$BD_ALIASES" ] || : > "$BD_ALIASES"
# `bd alias` may exist on newer Beads — but writing the toml directly is
# the supported documented path on 1.0.3, where the verb isn't shipped yet.
if /usr/bin/grep -q 'paperflow-e5v: hide kind:event' "$BD_ALIASES" 2>/dev/null; then
    skip "alias block already present"
else
    {
        printf '\n# paperflow-e5v: hide kind:event from default bd list/ready\n'
        printf '[[alias]]\n'
        printf 'name = "list"\n'
        printf 'default-args = ["--exclude-label", "kind:event"]\n'
        printf '[[alias]]\n'
        printf 'name = "ready"\n'
        printf 'default-args = ["--exclude-label", "kind:event"]\n'
    } >> "$BD_ALIASES"
    ok "appended kind:event filter blocks to $BD_ALIASES"
    skip "if your bd version ignores ~/.beads/aliases.toml, run: bd list --exclude-label kind:event"
fi

# ─── 10g. Migration: legacy goals → Beads ──────────────────────────
log "Migration: legacy goals → Beads"
if "$HOME/.local/bin/paperflow-migrate-legacy-goals"; then
    ok "migration complete"
else
    err "migration failed — check stderr above; legacy files preserved untouched"
fi

# ─── 11. CLAUDE.md (preamble refresh + optional --with-* fragments) ─
# Render lean core + append integration fragments for whichever
# --with-* flags fired. After --reset the file is gone, so the
# create-fresh branch fires naturally.
#
# Refresh model: the rendered template lives between
#   <!-- paperflow:preamble:begin --> … <!-- paperflow:preamble:end -->
# sentinels. Re-running install.sh replaces just that block, so user
# customisations outside the sentinels are preserved verbatim.
log "~/.claude/CLAUDE.md"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"

render_claude_md() {
    local dst="$1" tmp
    tmp="$(mktemp)"
    render "$REPO/claude-md.tmpl" "$tmp" ""
    # Append fragments in a stable order: openclaw, browserbase, unlighthouse.
    if [ "$WITH_OPENCLAW" -eq 1 ] && [ -f "$REPO/claude-md-fragments/openclaw.md" ]; then
        printf '\n\n' >> "$tmp"
        cat "$REPO/claude-md-fragments/openclaw.md" >> "$tmp"
    fi
    if [ "$WITH_BROWSERBASE" -eq 1 ] && [ -f "$REPO/claude-md-fragments/browserbase.md" ]; then
        printf '\n\n' >> "$tmp"
        cat "$REPO/claude-md-fragments/browserbase.md" >> "$tmp"
    fi
    if [ "$WITH_UNLIGHTHOUSE" -eq 1 ] && [ -f "$REPO/claude-md-fragments/unlighthouse.md" ]; then
        printf '\n\n' >> "$tmp"
        cat "$REPO/claude-md-fragments/unlighthouse.md" >> "$tmp"
    fi
    mv "$tmp" "$dst"
}

append_fragment_if_missing() {
    # $1 = sentinel slug (e.g. "openclaw"); $2 = fragment file path
    local slug="$1" frag="$2"
    local sentinel="<!-- paperflow:with-${slug} -->"
    [ -f "$frag" ] || { skip "fragment missing: $frag"; return 0; }
    if grep -qF "$sentinel" "$CLAUDE_MD" 2>/dev/null; then
        skip "fragment $slug already in CLAUDE.md"
        return 0
    fi
    {
        printf '\n\n%s\n' "$sentinel"
        cat "$frag"
    } >> "$CLAUDE_MD"
    ok "appended $slug fragment to CLAUDE.md"
}

# Preamble sentinels — let install.sh refresh just the paperflow-managed
# section without touching user-authored prose. Wrap the rendered template
# between these markers so a re-run replaces the block in-place.
PREAMBLE_BEGIN="<!-- paperflow:preamble:begin -->"
PREAMBLE_END="<!-- paperflow:preamble:end -->"

write_fresh_claude_md() {
    # Fresh-render path (used when the file is missing). Preamble is wrapped
    # in begin/end sentinels so a follow-up re-run can refresh it in place.
    local dst="$1" rendered tmp
    rendered="$(mktemp)"
    render "$REPO/claude-md.tmpl" "$rendered" ""
    tmp="$(mktemp)"
    {
        printf '%s\n' "$PREAMBLE_BEGIN"
        cat "$rendered"
        printf '\n%s\n' "$PREAMBLE_END"
    } > "$tmp"
    mv "$tmp" "$dst"
    rm -f "$rendered" 2>/dev/null || true
}

refresh_preamble_in_place() {
    # Sentinel-block refresh. If the begin/end sentinels exist, replace the
    # block between them with the freshly rendered template. Otherwise prepend
    # the wrapped block so the user's custom content stays put underneath.
    local dst="$1" rendered tmp
    rendered="$(mktemp)"
    render "$REPO/claude-md.tmpl" "$rendered" ""
    tmp="$(mktemp)"
    if grep -qF "$PREAMBLE_BEGIN" "$dst" && grep -qF "$PREAMBLE_END" "$dst"; then
        # Replace the existing sentinel block (awk preserves everything outside it).
        awk -v begin="$PREAMBLE_BEGIN" -v end="$PREAMBLE_END" -v rfile="$rendered" '
            BEGIN { in_block = 0 }
            $0 == begin {
                print begin
                while ((getline line < rfile) > 0) print line
                print end
                in_block = 1
                next
            }
            $0 == end { in_block = 0; next }
            in_block == 0 { print }
        ' "$dst" > "$tmp"
        mv "$tmp" "$dst"
        ok "refreshed paperflow preamble block (sentinel-replace)"
    else
        # No sentinels yet — prepend the wrapped block, keep the user's content.
        {
            printf '%s\n' "$PREAMBLE_BEGIN"
            cat "$rendered"
            printf '\n%s\n\n' "$PREAMBLE_END"
            cat "$dst"
        } > "$tmp"
        mv "$tmp" "$dst"
        ok "prepended paperflow preamble block (sentinels added; user content preserved)"
    fi
    rm -f "$rendered" 2>/dev/null || true
}

if [ -f "$CLAUDE_MD" ]; then
    # Always refresh the sentinel-wrapped paperflow preamble — user content
    # outside the block is never touched. Then run the --merge flow for any
    # opt-in --with-* fragments.
    refresh_preamble_in_place "$CLAUDE_MD"
    if [ "$MERGE_CLAUDEMD" -eq 1 ]; then
        # Merge mode: append any --with-* fragments that aren't already present.
        # Sentinel-driven idempotency — re-running with the same flags is a no-op.
        [ "$WITH_OPENCLAW" -eq 1 ]     && append_fragment_if_missing openclaw     "$REPO/claude-md-fragments/openclaw.md"
        [ "$WITH_BROWSERBASE" -eq 1 ]  && append_fragment_if_missing browserbase  "$REPO/claude-md-fragments/browserbase.md"
        [ "$WITH_UNLIGHTHOUSE" -eq 1 ] && append_fragment_if_missing unlighthouse "$REPO/claude-md-fragments/unlighthouse.md"
        if [ "$WITH_OPENCLAW" -eq 0 ] && [ "$WITH_BROWSERBASE" -eq 0 ] && [ "$WITH_UNLIGHTHOUSE" -eq 0 ]; then
            skip "--merge passed but no --with-* flags set (nothing to append)"
        fi
    fi
else
    write_fresh_claude_md "$CLAUDE_MD"
    # Tag the freshly-rendered file with sentinels for whatever fragments shipped,
    # so a follow-up `--merge` won't double-append the same prose.
    [ "$WITH_OPENCLAW" -eq 1 ]     && printf '\n<!-- paperflow:with-openclaw -->\n'     >> "$CLAUDE_MD"
    [ "$WITH_BROWSERBASE" -eq 1 ]  && printf '\n<!-- paperflow:with-browserbase -->\n'  >> "$CLAUDE_MD"
    [ "$WITH_UNLIGHTHOUSE" -eq 1 ] && printf '\n<!-- paperflow:with-unlighthouse -->\n' >> "$CLAUDE_MD"
    ok "written (fragments: openclaw=$WITH_OPENCLAW browserbase=$WITH_BROWSERBASE unlighthouse=$WITH_UNLIGHTHOUSE)"
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
    # Per-instance bridges (paperflow-22c) are owned by individual Claude
    # Code sessions, not the installer. The port may be free at install time
    # if no session is active — treat absence as informational, not a failure.
    if wait_for_port 8766 2; then
        ok "claude-bridge : up    (http://localhost:8766, per-instance)"
    else
        skip "claude-bridge : not up at install time (spawned per session)"
    fi
    if wait_for_port 8765 2; then
        ok "paperflow-aux : up    (http://localhost:8765)"
    else
        skip "paperflow-aux : not yet responding on 8765 (may share port with live-server)"
    fi
    status_f "$CLAUDE_MD"                                "CLAUDE.md    "
    status_x "$HOME/.claude/hooks/inject-principles.sh"  "inject hook  "
    status_x "$HOME/.claude/hooks/auto-open-doc.sh"      "open hook    "
    status_f "$HOME/docs/paperflow/_lib/doc.js"          "doc renderer "
    status_f "$HOME/docs/paperflow/_lib/grill.js"        "grill render."
    if [ "$PAPERFLOW_PLUGIN_INSTALLED" = "1" ]; then
        ok "skills        : 8 via plugin (/paperflow:goal, /paperflow:plan, …, /paperflow:autopilot, /paperflow:setup)"
    else
        status_f "$HOME/.claude/skills/goal/SKILL.md"      "goal skill   "
        status_f "$HOME/.claude/skills/plan/SKILL.md"      "plan skill   "
        status_f "$HOME/.claude/skills/build/SKILL.md"     "build skill  "
        status_f "$HOME/.claude/skills/review/SKILL.md"    "review skill "
        status_f "$HOME/.claude/skills/install/SKILL.md"   "install skill"
        status_f "$HOME/.claude/skills/resume/SKILL.md"    "resume skill "
        status_f "$HOME/.claude/skills/setup/SKILL.md"     "setup skill  "
        status_f "$HOME/.claude/skills/autopilot/SKILL.md" "autopilot    "
    fi
    [ -d "$HOME/docs/paperflow/audits" ]                      && ok "audits dir    : ready"      || err "audits dir    : missing"
    status_x "$HOME/.claude/hooks/validate-paperflow-doc.sh"  "validate hook"
    status_x "$HOME/.claude/hooks/event-on-save.sh"           "event hook   "
    [ -d "$HOME/.paperflow/events" ]                          && ok "events dir    : ready"      || err "events dir    : missing"
    status_f "$HOME/docs/paperflow/_lib/goal-path-rail.js"    "rail renderer"
    status_f "$HOME/docs/paperflow/_lib/text-diff.js"         "text-diff lib"
    status_x "$HOME/.local/bin/paperflow-target"              "target helper"
    status_x "$HOME/.local/bin/paperflow-aux-daemon"          "aux daemon   "
    status_x "$HOME/.local/bin/paperflow-continue"            "continue laun."
    status_x "$HOME/.local/bin/paperflow-validate"            "validator    "
    status_x "$HOME/.local/bin/paperflow-audit-site"          "audit wrapper"
    status_x "$HOME/.local/bin/paperflow-preflight"           "preflight    "
    status_x "$HOME/.local/bin/paperflow-doctor"              "doctor       "
    status_x "$HOME/.local/bin/paperflow-doc-meta"            "doc-meta     "
    status_x "$HOME/.local/bin/paperflow-migrate-legacy-goals" "migrate helper"
    status_x "$HOME/.local/bin/paperflow-goal-merge"          "goal-merge   "
    status_x "$HOME/.local/bin/paperflow-claim-files"         "claim-files  "
    status_x "$HOME/.local/bin/pf"                            "pf wrapper  "
    status_x "$HOME/.local/bin/paperflow-audit-orchestrator-budget" "audit helper "
    status_x "$HOME/.local/bin/paperflow-dock-daemon"         "dock daemon  "
    status_x "$HOME/.local/bin/paperflow-dock-feed"           "dock feed    "
    [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/cmux/dock.json" ]  && ok "dock config   : present"    || skip "dock config   : missing"
    if [ -S "$HOME/.paperflow/dock.sock" ] \
       && printf 'active-context\n' | /usr/bin/nc -U -w 1 "$HOME/.paperflow/dock.sock" >/dev/null 2>&1; then
        ok "dock daemon   : running    (~/.paperflow/dock.sock)"
    else
        skip "dock daemon   : not running (re-run install.sh to respawn)"
    fi
    jq -e '.hooks.UserPromptSubmit' "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings UPS  : wired"      || err "settings UPS  : broken"
    jq -e '.hooks.PostToolUse'      "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings PTU  : wired"      || err "settings PTU  : broken"
    status_x "$HOME/.claude/statusline.sh"                       "statusline   "
    status_f "$HOME/.paperflow/statusline-limits.json"           "limits.json  "
    status_f "$HOME/.paperflow/.statusline-installed-sha"        "sl sidecar   "
    [ -f "$HOME/.paperflow/.statusline-limits-installed-sha" ] && ok "limits sidecar: present" || err "limits sidecar: missing"
    jq -e '.statusLine' "$SETTINGS" >/dev/null 2>&1 \
                                                       && ok "settings stat.: wired"      || skip "settings stat.: not wired (foreign or absent)"
}

# ─── Self-test ─────────────────────────────────────────────────────
# End-to-end smoke check on the three load-bearing services. Runs AFTER
# the verbose status block so users see the per-component truth first,
# then a single pass/fail gate. Hard-fails the install on any breakage —
# better to stop here than ship a half-broken paperflow with a green
# closer message.
echo
log "Self-test"

selftest_fail() {
    err "self-test failed: $1"
    printf '    \033[2m%s\033[0m\n' "$2" >&2
    printf '\n  \033[1;31m✗\033[0m install completed but a service is unhealthy. Fix the above, then re-run.\n\n' >&2
    exit 1
}

# 1. Active-scope resolver — must exit 0 and print a non-empty scope.
if SCOPE="$("$HOME/.local/bin/paperflow-active-scope" --resolve 2>/dev/null)" && [ -n "$SCOPE" ]; then
    ok "scope resolver: $SCOPE"
else
    selftest_fail "paperflow-active-scope --resolve returned non-zero or empty" \
                  "Inspect: $HOME/.local/bin/paperflow-active-scope --resolve"
fi

# 2. Per-instance bridge (paperflow-22c) — owned by Claude Code sessions,
# not the installer. Probe 8766 informationally only; a fresh install with no
# active session has no bridge to probe and must not fail here.
if curl -fsS --max-time 2 -o /dev/null http://localhost:8766/ 2>/dev/null \
   || curl -sS  --max-time 2 -o /dev/null -w '%{http_code}' http://localhost:8766/ 2>/dev/null \
        | grep -qE '^[2345]'; then
    ok "bridge port 8766 (a session is up)"
else
    ok "bridge port 8766: no active session (per-instance bridges spawn on SessionStart)"
fi

# 3. Live-server on 8765 — same tolerant check.
if curl -fsS --max-time 2 -o /dev/null http://localhost:8765/ 2>/dev/null \
   || curl -sS  --max-time 2 -o /dev/null -w '%{http_code}' http://localhost:8765/ 2>/dev/null \
        | grep -qE '^[2345]'; then
    ok "live-server port 8765"
else
    selftest_fail "live-server not responding on port 8765" \
                  "Inspect: launchctl list | grep docs-livereload    (and: lsof -i :8765)"
fi

# 4. Preflight helper — verifies it's installed and reports ok end-to-end.
if "$HOME/.local/bin/paperflow-preflight" >/dev/null 2>&1; then
    ok "preflight        : ok"
else
    err "preflight        : reported failure (rerun manually to see JSON)"
fi

# 5. Doctor helper — fast health probe (warnings → exit 1, critical → exit 2).
if "$HOME/.local/bin/paperflow-doctor" --fast >/dev/null 2>&1; then
    ok "doctor           : ok"
else
    DOCTOR_EXIT=$?
    if [ "$DOCTOR_EXIT" = "1" ]; then
        ok "doctor           : ok with warnings (run paperflow-doctor --full)"
    else
        err "doctor           : exit $DOCTOR_EXIT (run paperflow-doctor manually for JSON)"
    fi
fi

# 6. Doc-meta helper — --no-auto-goal so a fresh install doesn't spawn a
# session Goal during the smoke check (the helper would otherwise auto-bd-init
# this repo if it has no .beads/ yet).
if "$HOME/.local/bin/paperflow-doc-meta" --no-auto-goal >/dev/null 2>&1; then
    ok "doc-meta         : ok"
else
    err "doc-meta         : reported failure (rerun manually for JSON)"
fi

# 7. pf wrapper — `pf version` is the cheapest sanity probe; it touches the
# dispatch table, color helpers, and plugin-cache lookup without spawning cmux.
if "$HOME/.local/bin/pf" version >/dev/null 2>&1; then
    ok "pf version       : ok"
else
    err "pf version       : failed (try: pf version)"
fi

echo
printf '\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '⚠  RESTART CLAUDE CODE  before testing.\n'
printf '   Already-running sessions do NOT pick up the newly installed:\n'
printf '     • hooks         (run /hooks to reload without restarting)\n'
printf '     • skills        (/paperflow:goal/plan/build/review/install/resume — restart only)\n'
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

# Write the sentinel marker so the setup skill can detect that a host-side
# install has succeeded at least once. Format:
#   version=<version>
#   ts=<iso-8601>
mkdir -p "$HOME/.paperflow"
PF_SENTINEL="$HOME/.paperflow/installed"
PF_VERSION="$(jq -r '.version // "0.1.0"' "$REPO/.claude-plugin/plugin.json" 2>/dev/null || echo '0.1.0')"
PF_TS="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
{
    printf 'version=%s\n' "$PF_VERSION"
    printf 'ts=%s\n' "$PF_TS"
} > "$PF_SENTINEL"

printf '\n\033[1m\033[1;32m ✓ paperflow installed\033[0m\n\n'
printf '  Try:  \033[1m/paperflow:goal "your first goal"\033[0m\n'
printf '  Then: \033[2mgrill, build, review\033[0m — see /paperflow/specs/\n\n'
