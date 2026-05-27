#!/usr/bin/env bash
# tests/active-scope-validate-up.sh — happy-path gate for W7c step 2.
#
# With PAPERFLOW_MIRROR_GOALS=1 and a reachable barkpark on :4001,
# seed a goal document, set the pointer to the matching doc_id, and
# assert --validate exits 0. NEVER touches :4000 (production daily
# driver). SKIPs (exit 0) when :4001 isn't up — matches the pattern
# of tests/doc-meta-mirror-up.sh.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/bin/paperflow-active-scope"
MIRROR_LIB="$REPO/lib/barkpark-mirror.sh"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

BARKPARK_URL="${PAPERFLOW_BARKPARK_URL:-http://localhost:4001}"
TOKEN="${BARKPARK_MIRROR_TOKEN:-barkpark-dev-token}"

case "$BARKPARK_URL" in
    *:4000*)
        red "FAIL: refusing to run validate-up test against :4000 (production)"
        exit 1
        ;;
esac

http_code="$(curl -s -m 1 -o /dev/null -w '%{http_code}' "$BARKPARK_URL/v1/tasks" \
                 -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo 000)"
case "$http_code" in
    2*|4*) ;;
    *) yellow "SKIP: barkpark not reachable at $BARKPARK_URL (http=$http_code)"; exit 0 ;;
esac

TMP="$(mktemp -d -t pf-validate-up.XXXXXX)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

UNIQ="$(date +%s)-$$"
GOAL_ID="paperflow-vup-${UNIQ}"

export PAPERFLOW_DIR="$TMP"
export PAPERFLOW_MIRROR_GOALS=1
export PAPERFLOW_BARKPARK_URL="$BARKPARK_URL"
export BARKPARK_MIRROR_TOKEN="$TOKEN"
export BARKPARK_MIRROR_LOG="$TMP/mirror.log"
unset CMUX_WORKSPACE_ID CMUX_SURFACE_REF CLAUDE_SESSION_ID

# 1. Seed the goal in barkpark via the existing mirror helper.
. "$MIRROR_LIB"
barkpark_mirror_goal "$GOAL_ID" "Validate-up goal $UNIQ" "vup-$UNIQ" >/dev/null 2>&1
if ! grep -q "ok: goal $GOAL_ID mirrored" "$BARKPARK_MIRROR_LOG"; then
    red "FAIL: could not seed barkpark with goal $GOAL_ID"
    cat "$BARKPARK_MIRROR_LOG"
    exit 1
fi
green "PASS: seeded goal $GOAL_ID in barkpark"

# 2. Write the pointer.
bash "$SCRIPT" --write goal "$GOAL_ID" >/dev/null 2>&1
got="$(bash "$SCRIPT" --read goal 2>/dev/null || true)"
if [ "$got" != "$GOAL_ID" ]; then
    red "FAIL: --read goal returned '$got', expected '$GOAL_ID'"
    exit 1
fi
green "PASS: pointer set to $GOAL_ID"

# 3. --validate must exit 0.
out="$(bash "$SCRIPT" --validate goal 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: --validate goal rc=$rc (expected 0)"
    printf '  output: %s\n' "$out"
    printf '  mirror-log tail:\n'
    tail -5 "$BARKPARK_MIRROR_LOG" 2>/dev/null
    exit 1
fi
green "PASS: --validate goal exit 0 with matching barkpark doc"

green "─── active-scope-validate-up: ALL PASS ───"
exit 0
