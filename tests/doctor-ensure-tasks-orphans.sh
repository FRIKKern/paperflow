#!/usr/bin/env bash
# tests/doctor-ensure-tasks-orphans.sh — W7d step 2 (paperflow-5ki).
#
# Asserts that when the synthetic store carries > 25% orphan tasks,
# orphan_task_count.status=fail and the overall ensure_tasks.ok=false.
#
# Doesn't require barkpark — the orphan check runs in dry-run mode
# (no curl traffic, verified by the importer's own test). Other checks
# may warn/fail depending on environment; we only assert the orphan
# row's status here.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO/bin/paperflow-doctor"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

TMPDIR_T="$(mktemp -d -t pf-ensure-orphans.XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Store: 1 goal + 1 phase + 2 in-phase tasks + 3 orphan tasks (60% orphan, > 25%).
STORE_DIR="$TMPDIR_T/.beads"
mkdir -p "$STORE_DIR"
cat > "$STORE_DIR/issues.jsonl" <<'EOF'
{"_type":"issue","id":"bd-orph-g","title":"G","status":"open","priority":2,"issue_type":"epic","labels":["goal-orph","kind:goal"]}
{"_type":"issue","id":"bd-orph-p","title":"build","status":"open","priority":2,"issue_type":"task","labels":["goal-orph","kind:phase","phase-build"]}
{"_type":"issue","id":"bd-orph-t1","title":"T1","status":"open","priority":2,"issue_type":"task","labels":["goal-orph","phase-build"]}
{"_type":"issue","id":"bd-orph-t2","title":"T2","status":"open","priority":2,"issue_type":"task","labels":["goal-orph","phase-build"]}
{"_type":"issue","id":"bd-orph-o1","title":"O1","status":"open","priority":2,"issue_type":"task","labels":["goal-orph"]}
{"_type":"issue","id":"bd-orph-o2","title":"O2","status":"open","priority":2,"issue_type":"task","labels":["goal-orph"]}
{"_type":"issue","id":"bd-orph-o3","title":"O3","status":"open","priority":2,"issue_type":"task","labels":["goal-orph"]}
EOF

# Wrapper that pins the importer at our synthetic store.
WRAPPER_BIN="$TMPDIR_T/bin"
mkdir -p "$WRAPPER_BIN"
cat > "$WRAPPER_BIN/paperflow-import-bd" <<EOF
#!/usr/bin/env bash
exec "$REPO/bin/paperflow-import-bd" --store "$STORE_DIR/issues.jsonl" "\$@"
EOF
chmod +x "$WRAPPER_BIN/paperflow-import-bd"

# Run with mirror env unset (default daily-driver shape) — we only care
# about the orphan_task_count row here.
out="$(PATH="$WRAPPER_BIN:$PATH" bash "$DOCTOR" --ensure-tasks 2>&1)"
rc=$?

fail=0

# Exit 2 expected (orphan check fails).
if [ "$rc" -ne 2 ]; then
    red "FAIL: ensure-tasks exit $rc (expected 2 — orphan threshold)"
    printf '%s\n' "$out"
    fail=1
else
    green "PASS: exit 2 on orphan threshold breach"
fi

ok="$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)"
if [ "$ok" = "false" ]; then
    green "PASS: ensure_tasks.ok=false"
else
    red "FAIL: ok=$ok (expected false)"; fail=1
fi

orph_status="$(printf '%s' "$out" | jq -r '.ensure_tasks.orphan_task_count.status' 2>/dev/null)"
orph_count="$(printf '%s' "$out" | jq -r '.ensure_tasks.orphan_task_count.count' 2>/dev/null)"
orph_pct="$(printf '%s' "$out" | jq -r '.ensure_tasks.orphan_task_count.percent' 2>/dev/null)"
if [ "$orph_status" = "fail" ]; then
    green "PASS: orphan_task_count.status=fail (count=$orph_count, $orph_pct%)"
else
    red "FAIL: orphan_task_count.status=$orph_status (expected fail)"
    printf '  detail: %s\n' "$(printf '%s' "$out" | jq -c '.ensure_tasks.orphan_task_count')"
    fail=1
fi

if [ "$orph_count" = "3" ]; then
    green "PASS: count=3 matches 3 synthetic orphans"
else
    red "FAIL: count=$orph_count (expected 3)"; fail=1
fi

exit "$fail"
