#!/usr/bin/env bash
# tests/doctor-ensure-tasks-clean.sh — W7d step 2 (paperflow-5ki).
#
# Asserts the happy path: with barkpark reachable + dual-write enabled +
# an active goal that lives in barkpark + recent importer log + zero
# orphans + bd-shim on PATH, every `ensure_tasks.*` check returns pass
# and the overall exit is 0.
#
# Mirrors tests/doc-meta-mirror-up.sh's barkpark-required convention:
# SKIPs (exit 0) when no barkpark is reachable on :4001. NEVER fires
# against :4000 (production daily driver port).

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO/bin/paperflow-doctor"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

BARKPARK_URL="${PAPERFLOW_BARKPARK_URL:-http://localhost:4001}"
TOKEN="${BARKPARK_MIRROR_TOKEN:-barkpark-dev-token}"

case "$BARKPARK_URL" in
    *:4000*) red "FAIL: refusing to run mirror-required test against :4000"; exit 1 ;;
esac

http_code="$(curl -s -m 1 -o /dev/null -w '%{http_code}' "$BARKPARK_URL/v1/tasks" \
                 -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo 000)"
case "$http_code" in
    2*|4*) ;;
    *) yellow "SKIP: barkpark not reachable at $BARKPARK_URL (http=$http_code)"; exit 0 ;;
esac

# ─── 1. Stage a clean store with one mirrored goal ─────────────────────
TMPDIR_T="$(mktemp -d -t pf-ensure-clean.XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

UNIQ="$(date +%s)-$$"
GOAL_ID="paperflow-clean-${UNIQ}"

# Mirror the goal to barkpark so active_goal_mirrored passes.
. "$REPO/lib/barkpark-mirror.sh"
PAPERFLOW_MIRROR_GOALS=1 PAPERFLOW_BARKPARK_URL="$BARKPARK_URL" \
    barkpark_mirror_goal "$GOAL_ID" "Clean test $UNIQ" "clean-$UNIQ" >/dev/null 2>&1

# Synthetic store with NO orphans — every task carries phase- + goal- labels.
STORE_DIR="$TMPDIR_T/.beads"
mkdir -p "$STORE_DIR"
cat > "$STORE_DIR/issues.jsonl" <<EOF
{"_type":"issue","id":"$GOAL_ID","title":"Goal","status":"open","priority":2,"issue_type":"epic","labels":["goal-clean-${UNIQ}","kind:goal"]}
{"_type":"issue","id":"bd-clean-p1","title":"build","status":"open","priority":2,"issue_type":"task","labels":["goal-clean-${UNIQ}","kind:phase","phase-build"]}
{"_type":"issue","id":"bd-clean-t1","title":"T1","status":"open","priority":2,"issue_type":"task","labels":["goal-clean-${UNIQ}","phase-build"]}
{"_type":"issue","id":"bd-clean-t2","title":"T2","status":"open","priority":2,"issue_type":"task","labels":["goal-clean-${UNIQ}","phase-build"]}
EOF

# Active goal pointer + scope-of-pid fake so paperflow-active-scope reads it.
FAKE_HOME="$TMPDIR_T/home"
mkdir -p "$FAKE_HOME/.paperflow"
printf '%s\n' "$GOAL_ID" > "$FAKE_HOME/.paperflow/active-goal"

# Recent importer log so importer_run_recent passes.
touch "$FAKE_HOME/.paperflow/importer-$(date +%s).log"

# Override default-store lookup by setting PAPERFLOW_BD_STORES (unused by
# importer) — instead, we patch the importer call path by ensuring the
# importer's default store paths don't find anything (use --store via PATH
# wrapper). Simpler: create a wrapper for paperflow-import-bd that points
# at our synthetic store.
WRAPPER_BIN="$TMPDIR_T/bin"
mkdir -p "$WRAPPER_BIN"
cat > "$WRAPPER_BIN/paperflow-import-bd" <<EOF
#!/usr/bin/env bash
exec "$REPO/bin/paperflow-import-bd" --store "$STORE_DIR/issues.jsonl" "\$@"
EOF
chmod +x "$WRAPPER_BIN/paperflow-import-bd"

# active-scope wrapper that always returns our GOAL_ID — the real one
# scopes off $CMUX_WORKSPACE_ID / $CLAUDE_SESSION_ID and we'd be poking
# at the user's real ~/.paperflow.
cat > "$WRAPPER_BIN/paperflow-active-scope" <<EOF
#!/usr/bin/env bash
[ "\$1" = "--read" ] && [ "\$2" = "goal" ] && printf '%s\n' "$GOAL_ID" && exit 0
exit 0
EOF
chmod +x "$WRAPPER_BIN/paperflow-active-scope"

# bd-shim wrapper so shim_on_path passes (we know real bd is on PATH).
cat > "$WRAPPER_BIN/bd-shim" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WRAPPER_BIN/bd-shim"

# Run doctor with HOME overridden so importer log lookup hits OUR dir.
out="$(HOME="$FAKE_HOME" PATH="$WRAPPER_BIN:$PATH" \
       PAPERFLOW_MIRROR_GOALS=1 PAPERFLOW_BARKPARK_URL="$BARKPARK_URL" \
       BARKPARK_MIRROR_TOKEN="$TOKEN" \
       bash "$DOCTOR" --ensure-tasks 2>&1)"
rc=$?

fail=0

if [ "$rc" -ne 0 ]; then
    red "FAIL: ensure-tasks exit $rc (expected 0)"
    printf '%s\n' "$out"
    fail=1
else
    green "PASS: clean state → exit 0"
fi

ok="$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)"
[ "$ok" = "true" ] || { red "FAIL: ok=$ok (expected true)"; fail=1; }
[ "$ok" = "true" ] && green "PASS: ensure_tasks.ok=true"

# All 6 checks present + all status=pass.
for key in barkpark_reachable dual_write_enabled active_goal_mirrored \
           importer_run_recent orphan_task_count shim_on_path; do
    s="$(printf '%s' "$out" | jq -r ".ensure_tasks.$key.status" 2>/dev/null)"
    if [ "$s" = "pass" ]; then
        green "PASS: $key=pass"
    else
        red "FAIL: $key=$s (expected pass)"
        printf '  detail: %s\n' "$(printf '%s' "$out" | jq -c ".ensure_tasks.$key")"
        fail=1
    fi
done

exit "$fail"
