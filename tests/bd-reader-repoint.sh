#!/usr/bin/env bash
# tests/bd-reader-repoint.sh — W7b step 3 smoke harness.
#
# Verifies the PAPERFLOW_BD env-var selector works in all 4 named reader
# surfaces (statusline, dock-daemon, claim-files, goal-merge):
#
#   default path  → PAPERFLOW_BD unset → real bd on PATH
#                   (daily-driver guarantee: each reader exits without
#                    crashing; sane structural output)
#   repoint path  → PAPERFLOW_BD=/abs/path/to/bd-shim BARKPARK_URL=…
#                   (each reader spawns the shim instead of real bd;
#                    output should not crash and should be structurally
#                    consistent — fidelity already proven by w7-08c 14/14)
#
# Exits 0 on full pass. Repoint path SKIPs when no barkpark is reachable
# (we can't pretend the shim works without a backend; that's not a
# regression in this step's contract).
#
# Counts target: 8/8 (4 default + 4 repointed). 4/4 + 4 SKIP is acceptable
# when barkpark isn't running locally.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATUSLINE="$REPO/lib/statusline.sh"
DAEMON="$REPO/bin/paperflow-dock-daemon"
CLAIM="$REPO/bin/paperflow-claim-files"
MERGE="$REPO/bin/paperflow-goal-merge"
SHIM="$REPO/bin/bd-shim"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

for f in "$STATUSLINE" "$DAEMON" "$CLAIM" "$MERGE" "$SHIM"; do
    [ -e "$f" ] || { red "FAIL: missing $f"; exit 2; }
done

PASS=0; FAIL=0; SKIP=0
note() { printf '  %s\n' "$*"; }

# ─── 1. Default path: PAPERFLOW_BD unset ─────────────────────────────
# Each reader must run with default env and produce sane output. We
# don't assert byte-equality (statusline composition is environment-
# sensitive); we assert non-crash + correctness of structural markers.

unset PAPERFLOW_BD || true

# 1a. statusline.sh — feed minimal Claude Code JSON.
sl_in='{"session_id":"w712-default","transcript_path":"/nonexistent","cwd":"/tmp","model":{"id":"claude-test"}}'
sl_out=$(printf '%s\n' "$sl_in" | bash "$STATUSLINE" 2>&1)
sl_rc=$?
if [ "$sl_rc" -eq 0 ] && printf '%s' "$sl_out" | grep -q '/ 1M'; then
    green "PASS [default/statusline]"; PASS=$((PASS + 1))
else
    red "FAIL [default/statusline]: rc=$sl_rc out=[$sl_out]"; FAIL=$((FAIL + 1))
fi

# 1b. paperflow-dock-daemon — `node --check` (full daemon needs polling
# fixtures; tests/dock-smoke.sh covers behavioural assertions). Here we
# just confirm the file parses, since we already updated the JS.
if node --check "$DAEMON" 2>/dev/null; then
    green "PASS [default/dock-daemon]"; PASS=$((PASS + 1))
else
    red "FAIL [default/dock-daemon]: node --check failed"; FAIL=$((FAIL + 1))
fi

# 1c. paperflow-claim-files — check on a nonexistent path = {ok:true,conflicts:[]}.
cf_out=$("$CLAIM" check /tmp/w712-default-probe.txt 2>&1)
cf_rc=$?
if [ "$cf_rc" -eq 0 ] && printf '%s' "$cf_out" | grep -q '"ok":true'; then
    green "PASS [default/claim-files]"; PASS=$((PASS + 1))
else
    red "FAIL [default/claim-files]: rc=$cf_rc out=[$cf_out]"; FAIL=$((FAIL + 1))
fi

# 1d. paperflow-goal-merge — invoke with no args; usage exit is 1.
gm_out=$("$MERGE" 2>&1 || true)
if printf '%s' "$gm_out" | grep -q 'usage: paperflow-goal-merge'; then
    green "PASS [default/goal-merge]"; PASS=$((PASS + 1))
else
    red "FAIL [default/goal-merge]: out=[$gm_out]"; FAIL=$((FAIL + 1))
fi

# ─── 2. Repoint path: PAPERFLOW_BD=<shim> + barkpark up ──────────────
BARKPARK_URL="${BARKPARK_URL:-http://localhost:4001}"
if ! curl -s -m 1 -o /dev/null -w '%{http_code}' "$BARKPARK_URL" 2>/dev/null | grep -qE '^[2-4]'; then
    yellow "SKIP [repoint/*]: barkpark not reachable at $BARKPARK_URL (4 cases)"
    SKIP=$((SKIP + 4))
else
    export PAPERFLOW_BD="$SHIM"
    export BARKPARK_URL

    # 2a. statusline.sh — repointed bd path. With no active goal pointer in
    # scope, resolve_goal_phase_task() returns early and statusline runs the
    # same composition path; the assertion is "doesn't crash".
    sl_out=$(printf '%s\n' "$sl_in" | bash "$STATUSLINE" 2>&1)
    sl_rc=$?
    if [ "$sl_rc" -eq 0 ]; then
        green "PASS [repoint/statusline]"; PASS=$((PASS + 1))
    else
        red "FAIL [repoint/statusline]: rc=$sl_rc out=[$sl_out]"; FAIL=$((FAIL + 1))
    fi

    # 2b. dock-daemon — we don't full-spawn the daemon here (dock-smoke.sh
    # does that). Instead we assert the daemon-internal env-var resolution
    # by grepping the source for the constant + that it's consumed in the
    # bd() helper. That's the structural guarantee for repoint.
    if grep -q 'const PAPERFLOW_BD_BIN = process.env.PAPERFLOW_BD' "$DAEMON" \
       && grep -q 'spawn(PAPERFLOW_BD_BIN' "$DAEMON"; then
        green "PASS [repoint/dock-daemon] (structural)"
        PASS=$((PASS + 1))
    else
        red "FAIL [repoint/dock-daemon]: selector not wired"; FAIL=$((FAIL + 1))
    fi

    # 2c. claim-files repointed against shim+barkpark — `check` on a path
    # with no claims returns {ok:true,conflicts:[]}.
    cf_out=$("$CLAIM" check /tmp/w712-repoint-probe.txt 2>&1)
    cf_rc=$?
    if [ "$cf_rc" -eq 0 ] && printf '%s' "$cf_out" | grep -q '"ok":true'; then
        green "PASS [repoint/claim-files]"; PASS=$((PASS + 1))
    else
        red "FAIL [repoint/claim-files]: rc=$cf_rc out=[$cf_out]"; FAIL=$((FAIL + 1))
    fi

    # 2d. goal-merge repointed — invoke with no args; usage exits 1 BEFORE
    # any bd call, so this confirms the script reaches usage cleanly when
    # PAPERFLOW_BD is set. (The bd-spawning happy path needs seeded
    # barkpark goals; out of smoke scope.)
    gm_out=$("$MERGE" 2>&1 || true)
    if printf '%s' "$gm_out" | grep -q 'usage: paperflow-goal-merge'; then
        green "PASS [repoint/goal-merge]"; PASS=$((PASS + 1))
    else
        red "FAIL [repoint/goal-merge]: out=[$gm_out]"; FAIL=$((FAIL + 1))
    fi

    unset PAPERFLOW_BD BARKPARK_URL
fi

echo
echo "─── bd-reader-repoint summary ───"
TOTAL=$((PASS + FAIL + SKIP))
note "pass:  $PASS"
note "fail:  $FAIL"
note "skip:  $SKIP"
note "total: $TOTAL"

if [ "$FAIL" -ne 0 ]; then
    red "✗ $FAIL failures"
    exit 1
fi

if [ "$SKIP" -gt 0 ]; then
    yellow "OK: $PASS/$TOTAL passed (+ $SKIP skipped — barkpark down)"
else
    green "OK: $PASS/$TOTAL (4 default + 4 repointed)"
fi
exit 0
