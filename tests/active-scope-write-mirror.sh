#!/usr/bin/env bash
# tests/active-scope-write-mirror.sh — composite check for W7c step 2.
#
# Tests:
#   1. With mirror env set and barkpark reachable, --write a pointer to
#      an EXISTING goal doc; --write succeeds, --validate passes.
#   2. --write a pointer to a NON-EXISTENT goal doc; --write still
#      succeeds (warn-only), but --validate exits 2.
#
# SKIPs (exit 0) when :4001 isn't reachable. NEVER touches :4000.

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
        red "FAIL: refusing to run write-mirror test against :4000 (production)"
        exit 1
        ;;
esac

http_code="$(curl -s -m 1 -o /dev/null -w '%{http_code}' "$BARKPARK_URL/v1/tasks" \
                 -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo 000)"
case "$http_code" in
    2*|4*) ;;
    *) yellow "SKIP: barkpark not reachable at $BARKPARK_URL (http=$http_code)"; exit 0 ;;
esac

TMP="$(mktemp -d -t pf-write-mirror.XXXXXX)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

UNIQ="$(date +%s)-$$"
EXISTS_ID="paperflow-wm-${UNIQ}"
GHOST_ID="paperflow-wmghost-${UNIQ}"

export PAPERFLOW_DIR="$TMP"
export PAPERFLOW_MIRROR_GOALS=1
export PAPERFLOW_BARKPARK_URL="$BARKPARK_URL"
export BARKPARK_MIRROR_TOKEN="$TOKEN"
export BARKPARK_MIRROR_LOG="$TMP/mirror.log"
unset CMUX_WORKSPACE_ID CMUX_SURFACE_REF CLAUDE_SESSION_ID

# Seed the existing goal in barkpark.
. "$MIRROR_LIB"
barkpark_mirror_goal "$EXISTS_ID" "Write-mirror goal $UNIQ" "wm-$UNIQ" >/dev/null 2>&1
if ! grep -q "ok: goal $EXISTS_ID mirrored" "$BARKPARK_MIRROR_LOG"; then
    red "FAIL: seed of $EXISTS_ID did not log success"
    cat "$BARKPARK_MIRROR_LOG"
    exit 1
fi
green "PASS: seeded $EXISTS_ID in barkpark"

# ─── 1. Existing goal — write succeeds, validate passes ────────────
out="$(bash "$SCRIPT" --write goal "$EXISTS_ID" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || { red "FAIL: --write rc=$rc for existing id: $out"; exit 1; }
green "PASS: --write goal $EXISTS_ID → rc=0"

out="$(bash "$SCRIPT" --validate goal 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: --validate goal for existing id rc=$rc (expected 0)"
    printf '  output: %s\n' "$out"
    exit 1
fi
green "PASS: --validate goal for $EXISTS_ID → rc=0"

# ─── 2. Ghost goal — write succeeds with warn, validate fails ──────
out="$(bash "$SCRIPT" --write goal "$GHOST_ID" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: --write goal $GHOST_ID rc=$rc (write should never fail on drift)"
    printf '  output: %s\n' "$out"
    exit 1
fi
# Confirm the warn fired on stderr — the message is logged via the
# _validate_pointer warn-mode branch.
case "$out" in
    *drift*|*"not found in barkpark"*) green "PASS: --write goal $GHOST_ID emitted drift warning on stderr" ;;
    *)
        # Warning is best-effort; if it didn't surface that's an issue
        # but the write itself must still succeed. We treat absence as
        # FAIL because the contract is "write warns + still writes".
        red "FAIL: --write goal $GHOST_ID did not emit drift warning"
        printf '  stderr: %s\n' "$out"
        exit 1
        ;;
esac

out="$(bash "$SCRIPT" --validate goal 2>&1)"
rc=$?
if [ "$rc" -ne 2 ]; then
    red "FAIL: --validate goal for ghost id rc=$rc (expected 2 = drift)"
    printf '  output: %s\n' "$out"
    exit 1
fi
green "PASS: --validate goal for $GHOST_ID → rc=2 (drift)"

green "─── active-scope-write-mirror: ALL PASS ───"
exit 0
