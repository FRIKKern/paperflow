#!/usr/bin/env bash
# tests/doc-meta-no-mirror.sh — daily-driver guarantee for W7c step 1.
#
# Asserts that running paperflow-doc-meta with the mirror env-vars UNSET
# produces JSON byte-equal to the pre-W7c shape (12 fixed top-level keys)
# AND writes zero entries to the mirror log. This is the contract that
# lets us land the dual-write code without touching the daily driver.
#
# Exit 0 on pass, 1 on fail.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOC_META="$REPO/bin/paperflow-doc-meta"
MIRROR_LIB="$REPO/lib/barkpark-mirror.sh"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# 1. Files exist
for f in "$DOC_META" "$MIRROR_LIB"; do
    [ -r "$f" ] || { red "FAIL: missing $f"; exit 2; }
done

# 2. Default env: PAPERFLOW_MIRROR_GOALS unset
unset PAPERFLOW_MIRROR_GOALS PAPERFLOW_BARKPARK_URL

# Run --no-auto-goal so the test never lands a real Goal in this repo's bd.
out="$(bash "$DOC_META" --no-auto-goal 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: doc-meta exit $rc, output:"; printf '%s\n' "$out"; exit 1
fi

# 3. Shape — must carry the same 12 keys the pre-W7c version emitted.
expected_keys="active_goal_id active_goal_title auto_created cmux_workspace date device ok repo_root time_display time_local ts tz"
got_keys="$(printf '%s' "$out" | jq -r 'keys | join(" ")' 2>/dev/null)"
if [ "$got_keys" != "$expected_keys" ]; then
    red "FAIL: key drift"
    printf '  expected: %s\n  got:      %s\n' "$expected_keys" "$got_keys"
    exit 1
fi
green "PASS: 12-key shape preserved"

# 4. ok=true
ok="$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)"
[ "$ok" = "true" ] || { red "FAIL: .ok != true (got $ok)"; exit 1; }
green "PASS: .ok = true"

# 5. Mirror log is NOT touched by a default-env run. Truncate first to
# isolate this run; if the file gains content under default env, the
# helper is leaking the no-op contract.
LOG="${BARKPARK_MIRROR_LOG:-$HOME/.paperflow/doc-meta-mirror.log}"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"
bash "$DOC_META" --no-auto-goal >/dev/null 2>&1
if [ -s "$LOG" ]; then
    red "FAIL: mirror log has entries after default-env run"
    head -5 "$LOG"
    exit 1
fi
green "PASS: mirror log untouched by default-env run"

# 6. paperflow-mirror-phase is also a hard no-op in default env.
out="$(bash "$REPO/bin/paperflow-mirror-phase" "test-phase-id" "build" "test-goal-id" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || { red "FAIL: mirror-phase exit $rc in default env"; printf '%s\n' "$out"; exit 1; }
if [ -s "$LOG" ]; then
    red "FAIL: mirror log written by mirror-phase in default env"
    head -5 "$LOG"
    exit 1
fi
green "PASS: paperflow-mirror-phase no-op in default env"

green "─── doc-meta-no-mirror: ALL PASS ───"
exit 0
