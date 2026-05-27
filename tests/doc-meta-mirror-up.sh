#!/usr/bin/env bash
# tests/doc-meta-mirror-up.sh — happy-path gate for W7c step 1.
#
# Asserts that when PAPERFLOW_MIRROR_GOALS=1 + PAPERFLOW_BARKPARK_URL is
# set to a reachable barkpark:
#   * paperflow-mirror-phase POSTs a type=phase document and the row is
#     subsequently visible via GET /v1/tasks?kind=phase
#   * barkpark_mirror_goal POSTs a type=goal document and the row is
#     visible via GET /v1/tasks?kind=goal
#   * mirror log carries 'ok:' lines for both
#
# SKIPs (exit 0) when no barkpark is reachable on the configured URL —
# matches the convention of tests/bd-reader-repoint.sh. NEVER fires
# against :4000 (the production daily-driver port). Default :4001.
#
# Exit 0 on pass or skip, 1 on hard fail.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MIRROR_LIB="$REPO/lib/barkpark-mirror.sh"
MIRROR_PHASE="$REPO/bin/paperflow-mirror-phase"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

BARKPARK_URL="${PAPERFLOW_BARKPARK_URL:-http://localhost:4001}"
TOKEN="${BARKPARK_MIRROR_TOKEN:-barkpark-dev-token}"

# Guardrail: never run against :4000 (production daily driver).
case "$BARKPARK_URL" in
    *:4000*)
        red "FAIL: refusing to run mirror-up test against :4000 (production)"
        exit 1
        ;;
esac

# Reachability probe — if barkpark isn't up here, SKIP cleanly.
http_code="$(curl -s -m 1 -o /dev/null -w '%{http_code}' "$BARKPARK_URL/v1/tasks" \
                 -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo 000)"
case "$http_code" in
    2*|4*) ;;  # 200 OK or 401/404 — barkpark is answering, proceed
    *)
        yellow "SKIP: barkpark not reachable at $BARKPARK_URL (http=$http_code)"
        exit 0
        ;;
esac

LOG="$(mktemp -t doc-meta-mirror-up.XXXXXX)"
UNIQ="$(date +%s)-$$"
GOAL_ID="paperflow-test-${UNIQ}"
PHASE_ID="paperflow-testp-${UNIQ}"

export BARKPARK_MIRROR_LOG="$LOG"
export PAPERFLOW_MIRROR_GOALS=1
export PAPERFLOW_BARKPARK_URL="$BARKPARK_URL"
export BARKPARK_MIRROR_TOKEN="$TOKEN"

# ─── 1. Goal mirror ────────────────────────────────────────────────────
. "$MIRROR_LIB"
barkpark_mirror_goal "$GOAL_ID" "Test goal $UNIQ" "test-$UNIQ" >/dev/null 2>&1

if ! grep -q "^.*ok: goal $GOAL_ID mirrored" "$LOG"; then
    red "FAIL: goal mirror did not log success"
    cat "$LOG"
    rm -f "$LOG"
    exit 1
fi
green "PASS: goal mirror logged ok"

# Verify the goal is visible via GET /v1/tasks?kind=goal. Barkpark
# prefixes inserted ids with "drafts." — match either form.
out="$(curl -sS -m 3 -H "Authorization: Bearer $TOKEN" \
        "$BARKPARK_URL/v1/tasks?kind=goal&limit=200" 2>&1)"
if ! printf '%s' "$out" | jq -e --arg id "$GOAL_ID" --arg drafted "drafts.$GOAL_ID" \
        '.docs[] | select(.doc_id == $id or .doc_id == $drafted)' >/dev/null 2>&1; then
    red "FAIL: goal $GOAL_ID not visible via GET /v1/tasks?kind=goal"
    printf '  resp: %s\n' "$out" | head -c 400
    rm -f "$LOG"
    exit 1
fi
green "PASS: goal visible via GET /v1/tasks?kind=goal"

# ─── 2. Phase mirror via the CLI helper ────────────────────────────────
out="$(bash "$MIRROR_PHASE" "$PHASE_ID" "build" "$GOAL_ID" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || { red "FAIL: mirror-phase exit $rc with barkpark up"; printf '%s\n' "$out"; rm -f "$LOG"; exit 1; }

if ! grep -q "^.*ok: phase $PHASE_ID mirrored" "$LOG"; then
    red "FAIL: phase mirror did not log success"
    cat "$LOG"
    rm -f "$LOG"
    exit 1
fi
green "PASS: phase mirror logged ok"

# Verify the phase is visible via GET /v1/tasks?kind=phase.
out="$(curl -sS -m 3 -H "Authorization: Bearer $TOKEN" \
        "$BARKPARK_URL/v1/tasks?kind=phase&limit=200" 2>&1)"
if ! printf '%s' "$out" | jq -e --arg id "$PHASE_ID" --arg drafted "drafts.$PHASE_ID" \
        '.docs[] | select(.doc_id == $id or .doc_id == $drafted)' >/dev/null 2>&1; then
    red "FAIL: phase $PHASE_ID not visible via GET /v1/tasks?kind=phase"
    printf '  resp: %s\n' "$out" | head -c 400
    rm -f "$LOG"
    exit 1
fi
green "PASS: phase visible via GET /v1/tasks?kind=phase"

rm -f "$LOG"
green "─── doc-meta-mirror-up: ALL PASS ───"
exit 0
