#!/usr/bin/env bash
# tests/doc-meta-mirror-down.sh — graceful-degradation gate for W7c step 1.
#
# Asserts that when the mirror is ENABLED but the barkpark URL is
# unreachable, doc-meta:
#   * still exits 0 (bd creation is authoritative — never blocked by the
#     mirror failing)
#   * emits its 12-key JSON shape unchanged
#   * writes a one-line "warn:" entry to the mirror log so the failure is
#     observable without the user seeing stderr noise
#
# This is the W7c reversibility contract — the daily driver continues to
# work even if barkpark is down.
#
# Exit 0 on pass, 1 on fail.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOC_META="$REPO/bin/paperflow-doc-meta"
MIRROR_PHASE="$REPO/bin/paperflow-mirror-phase"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

LOG="$(mktemp -t doc-meta-mirror-down.XXXXXX)"
export BARKPARK_MIRROR_LOG="$LOG"
export PAPERFLOW_MIRROR_GOALS=1
# Port 9999 is the documented "definitely-not-barkpark" probe — connect
# should fail immediately, well under the 3 s curl timeout.
export PAPERFLOW_BARKPARK_URL="http://localhost:9999"

# 1. paperflow-mirror-phase against the bogus URL — exits 0, logs warn.
: > "$LOG"
out="$(bash "$MIRROR_PHASE" "phase-down-test" "build" "goal-down-test" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: mirror-phase exit $rc with barkpark down"
    printf '  stderr: %s\n' "$out"
    rm -f "$LOG"
    exit 1
fi
green "PASS: mirror-phase exit 0 with barkpark down"

if ! grep -q '^.*warn: phase mirror curl failed' "$LOG"; then
    red "FAIL: expected 'warn: phase mirror curl failed' in log"
    cat "$LOG"
    rm -f "$LOG"
    exit 1
fi
green "PASS: 'warn: phase mirror curl failed' logged"

# 2. doc-meta --no-auto-goal — no goal to mirror, so no log line, BUT it
# must still exit 0 with the 12-key shape (the mirror sourcing must not
# break the script in any env).
out="$(bash "$DOC_META" --no-auto-goal 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: doc-meta --no-auto-goal exit $rc when mirror enabled+down"
    printf '  output: %s\n' "$out"
    rm -f "$LOG"
    exit 1
fi
got_keys="$(printf '%s' "$out" | jq -r 'keys | join(" ")' 2>/dev/null)"
expected_keys="active_goal_id active_goal_title auto_created cmux_workspace date device ok repo_root time_display time_local ts tz"
if [ "$got_keys" != "$expected_keys" ]; then
    red "FAIL: key drift with mirror enabled+down"
    printf '  expected: %s\n  got:      %s\n' "$expected_keys" "$got_keys"
    rm -f "$LOG"
    exit 1
fi
green "PASS: doc-meta shape preserved with mirror enabled+down"

# 3. Sanity — the goal-mirror function (sourced into doc-meta) must also
# tolerate the bogus URL. Source the lib + call directly.
. "$REPO/lib/barkpark-mirror.sh"
: > "$LOG"
barkpark_mirror_goal "goal-down-test" "Test goal down" "down-test" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: barkpark_mirror_goal returned nonzero ($rc) with bogus URL"
    rm -f "$LOG"
    exit 1
fi
if ! grep -q '^.*warn: goal mirror curl failed' "$LOG"; then
    red "FAIL: expected 'warn: goal mirror curl failed' in log"
    cat "$LOG"
    rm -f "$LOG"
    exit 1
fi
green "PASS: barkpark_mirror_goal returns 0 + logs warn with bogus URL"

rm -f "$LOG"
green "─── doc-meta-mirror-down: ALL PASS ───"
exit 0
