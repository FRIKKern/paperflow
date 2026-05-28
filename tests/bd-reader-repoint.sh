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

    # 2c. claim-files repointed against shim+barkpark — FULL round-trip (tt5).
    # Previously this only ran `check` on an empty path (which can't fail —
    # an empty result set is the no-conflict case regardless of whether the
    # file-claim label filter actually works). tt5 closes that gap: the shim
    # now translates `--add-label` / `--remove-label` (→ POST /labels) and
    # `list --label file-claim:X` (→ GET ?label=), so we exercise the whole
    # claim → check(conflict) → release → check(clean) lifecycle against a
    # real seeded task. This is the case that FAILED before tt5 (no
    # --add-label path; arbitrary labels fell through unfiltered).
    #
    # Discover a task to claim against (any seeded task row). If barkpark has
    # no tasks at all we can't exercise the round-trip — SKIP that sub-check
    # rather than fail (a fresh/empty barkpark isn't a regression in the shim).
    cf_probe="/tmp/tt5-repoint-claim-$$.ex"
    cf_task="$("$SHIM" list --type task --json 2>/dev/null \
                | jq -r '[.[] | select(.issue_type=="task")][0].id // empty')"
    if [ -z "$cf_task" ]; then
        yellow "SKIP [repoint/claim-files]: no seeded task to claim against"
        SKIP=$((SKIP + 1))
    else
        cf_ok=1
        # check before — no claim yet → ok:true, conflicts:[]
        cf_before=$("$CLAIM" check "$cf_probe" 2>&1); cf_before_rc=$?
        [ "$cf_before_rc" -eq 0 ] && printf '%s' "$cf_before" | grep -q '"conflicts":\[\]' || cf_ok=0

        # claim the file on the discovered task → ok:true
        cf_claim=$("$CLAIM" claim "$cf_task" "$cf_probe" 2>&1); cf_claim_rc=$?
        [ "$cf_claim_rc" -eq 0 ] && printf '%s' "$cf_claim" | grep -q '"ok":true' || cf_ok=0

        # check after claim — the holder must surface as a conflict, rc=2.
        # This is the assertion the list --label file-claim:X filter powers.
        cf_after=$("$CLAIM" check "$cf_probe" 2>&1); cf_after_rc=$?
        [ "$cf_after_rc" -eq 2 ] && printf '%s' "$cf_after" | grep -q "$cf_task" || cf_ok=0

        # release the task → claim drops, check is clean again.
        "$CLAIM" release "$cf_task" >/dev/null 2>&1
        cf_clean=$("$CLAIM" check "$cf_probe" 2>&1); cf_clean_rc=$?
        [ "$cf_clean_rc" -eq 0 ] && printf '%s' "$cf_clean" | grep -q '"conflicts":\[\]' || cf_ok=0

        if [ "$cf_ok" -eq 1 ]; then
            green "PASS [repoint/claim-files] (claim→check→release round-trip)"
            PASS=$((PASS + 1))
        else
            red "FAIL [repoint/claim-files]: before=[$cf_before] claim=[$cf_claim] after(rc=$cf_after_rc)=[$cf_after] clean=[$cf_clean]"
            FAIL=$((FAIL + 1))
        fi
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
