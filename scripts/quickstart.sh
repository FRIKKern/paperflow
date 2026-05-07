#!/usr/bin/env bash
# paperflow quickstart — one-line install.
#   curl -fsSL https://raw.githubusercontent.com/FRIKKern/paperflow/main/scripts/quickstart.sh | bash
set -euo pipefail

C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_CYAN=$'\033[1;36m'
C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_RST=$'\033[0m'

banner() { printf '\n%s%s paperflow %s· beautiful specs, plans, and grills for Claude Code%s\n\n' "$C_BOLD" "$C_CYAN" "$C_DIM" "$C_RST"; }
ok()     { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
die()    { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$1" >&2; [ -n "${2:-}" ] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_RST" >&2; exit 1; }

# auto_install <display-name> <binary-name> <fallback-hint>
# If <binary-name> is on PATH, ok and return. Otherwise try `brew install <display-name>`
# silently; for "beads" specifically, fall back to `npm install -g beads`. If both
# attempts fail (or neither tool is available), die with the supplied hint.
auto_install() {
    local tool="$1"
    local cmd="$2"
    local hint="$3"

    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$tool"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        printf '  %s•%s installing %s via brew…\n' "$C_DIM" "$C_RST" "$tool"
        if brew install "$tool" >/dev/null 2>&1; then
            ok "$tool (auto-installed)"
            return 0
        fi
    fi

    if [ "$tool" = "beads" ] && command -v npm >/dev/null 2>&1; then
        printf '  %s•%s installing beads via npm…\n' "$C_DIM" "$C_RST"
        if npm install -g beads >/dev/null 2>&1; then
            ok "beads (auto-installed via npm)"
            return 0
        fi
    fi

    die "$tool is required." "$hint"
}

# --yes pass-through for unattended installs.
if [ "${1:-}" = "--yes" ]; then
    export PAPERFLOW_YES=1
fi

banner
printf '%sTakes about a minute. Sets up two LaunchAgents, two hooks, three skills, and the article-style renderers.%s\n\n' "$C_DIM" "$C_RST"

# ── Pre-reqs ────────────────────────────────────────────────────────
need_node22() {
    if [ -d "$HOME/.nvm/versions/node" ] && ls -d "$HOME/.nvm/versions/node"/v22.*/bin/node >/dev/null 2>&1; then return 0; fi
    if command -v node >/dev/null 2>&1; then
        local nv; nv="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
        [ "${nv:-0}" -ge 22 ] && return 0
    fi
    return 1
}
need_node22 || die "Node 22+ is required." "Install:  brew install node    (or: brew install nvm && nvm install 22)"
ok "Node 22+"

auto_install jq jq "Install:  brew install jq    (or install Homebrew first: https://brew.sh)"

auto_install beads bd "Install:  brew install beads    (or: npm i -g beads)"

command -v git >/dev/null 2>&1 || die "git is required." "Install:  xcode-select --install"
ok "git"

if command -v gh >/dev/null 2>&1; then ok "gh (optional)"; else printf '  %s•%s gh (optional, skipped)\n' "$C_DIM" "$C_RST"; fi

# ── Locate / clone repo ─────────────────────────────────────────────
DEFAULT_PRIMARY="$HOME/Documents/GitHub/paperflow"
DEFAULT_FALLBACK="$HOME/paperflow"
REPO=""
for d in "$DEFAULT_PRIMARY" "$DEFAULT_FALLBACK"; do [ -d "$d/.git" ] && REPO="$d" && break; done

if [ -z "$REPO" ]; then
    REPO="$DEFAULT_PRIMARY"
    mkdir -p "$(dirname "$REPO")"
    printf '\n%s▸%s Cloning paperflow → %s\n' "$C_CYAN" "$C_RST" "$REPO"
    git clone --quiet https://github.com/FRIKKern/paperflow.git "$REPO" || die "Clone failed." "Check your network or run: git clone https://github.com/FRIKKern/paperflow.git \"$REPO\""
    ok "cloned"
else
    printf '\n%s▸%s Using existing checkout at %s\n' "$C_CYAN" "$C_RST" "$REPO"
    if git -C "$REPO" remote get-url origin >/dev/null 2>&1 && git -C "$REPO" rev-parse --verify origin/main >/dev/null 2>&1; then
        if git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet; then
            git -C "$REPO" pull --quiet --ff-only origin main 2>/dev/null && ok "pulled latest" || ok "kept local (pull skipped)"
        else
            ok "kept local edits (skipping pull)"
        fi
    fi
fi

# ── Run install.sh ──────────────────────────────────────────────────
printf '\n%s▸%s Running installer\n\n' "$C_CYAN" "$C_RST"
INSTALL_ARGS=()
[ "${PAPERFLOW_YES:-0}" = 1 ] && INSTALL_ARGS+=(--yes)
bash "$REPO/install.sh" "${INSTALL_ARGS[@]}"

# ── Finish ──────────────────────────────────────────────────────────
printf '\n%sYou'\''re ready.%s Here'\''s what to try first:\n' "$C_BOLD" "$C_RST"
printf '  1. In Claude Code, ask: %s"write a spec for <your idea>"%s — it auto-opens in your browser.\n' "$C_CYAN" "$C_RST"
printf '  2. Click %sGrill the spec%s — answer the form, send back.\n' "$C_CYAN" "$C_RST"
printf '  3. Click %sCreate plan from this spec%s — then %sBuild this plan%s.\n\n' "$C_CYAN" "$C_RST" "$C_CYAN" "$C_RST"
