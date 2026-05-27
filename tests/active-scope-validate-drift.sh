#!/usr/bin/env bash
# tests/active-scope-validate-drift.sh — drift detection for W7c step 2.
#
# With PAPERFLOW_MIRROR_GOALS=1 + barkpark reachable on :4001, write a
# pointer to an id that DOES NOT exist in barkpark and assert that
# --validate exits 2 (drift). NEVER touches :4000. SKIPs when :4001
# is down.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/bin/paperflow-active-scope"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

BARKPARK_URL="${PAPERFLOW_BARKPARK_URL:-http://localhost:4001}"
TOKEN="${BARKPARK_MIRROR_TOKEN:-barkpark-dev-token}"

case "$BARKPARK_URL" in
    *:4000*)
        red "FAIL: refusing to run validate-drift test against :4000 (production)"
        exit 1
        ;;
esac

http_code="$(curl -s -m 1 -o /dev/null -w '%{http_code}' "$BARKPARK_URL/v1/tasks" \
                 -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo 000)"
case "$http_code" in
    2*|4*) ;;
    *) yellow "SKIP: barkpark not reachable at $BARKPARK_URL (http=$http_code)"; exit 0 ;;
esac

TMP="$(mktemp -d -t pf-validate-drift.XXXXXX)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

UNIQ="$(date +%s)-$$"
# A goal id that we deliberately never seed.
GHOST_ID="paperflow-ghost-${UNIQ}"

export PAPERFLOW_DIR="$TMP"
export PAPERFLOW_MIRROR_GOALS=1
export PAPERFLOW_BARKPARK_URL="$BARKPARK_URL"
export BARKPARK_MIRROR_TOKEN="$TOKEN"
export BARKPARK_MIRROR_LOG="$TMP/mirror.log"
unset CMUX_WORKSPACE_ID CMUX_SURFACE_REF CLAUDE_SESSION_ID

# 1. Write pointer for ghost id (--write warns to stderr but still 0).
out="$(bash "$SCRIPT" --write goal "$GHOST_ID" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: --write goal ghost id rc=$rc (expected 0, warn-only)"
    printf '  output: %s\n' "$out"
    exit 1
fi
green "PASS: --write goal ghost id succeeds with warn (rc=0)"

# 2. --validate must exit 2 (drift).
out="$(bash "$SCRIPT" --validate goal 2>&1)"
rc=$?
if [ "$rc" -ne 2 ]; then
    red "FAIL: --validate goal ghost id rc=$rc (expected 2 = drift)"
    printf '  output: %s\n' "$out"
    exit 1
fi
case "$out" in
    *drift*) ;;
    *) red "FAIL: drift message missing from stderr: $out"; exit 1 ;;
esac
green "PASS: --validate goal ghost id → exit 2 with drift message"

# 3. Empty pointer → exit 1 (not 2).
rm -f "$TMP"/active-goal*
out="$(bash "$SCRIPT" --validate goal 2>&1)"
rc=$?
if [ "$rc" -ne 1 ]; then
    red "FAIL: --validate goal with no pointer rc=$rc (expected 1)"
    printf '  output: %s\n' "$out"
    exit 1
fi
green "PASS: --validate goal with empty pointer → exit 1"

green "─── active-scope-validate-drift: ALL PASS ───"
exit 0
