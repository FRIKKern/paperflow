#!/usr/bin/env bash
# tests/doctor-ensure-tasks-orphans.sh — W7d step 2 (paperflow-5ki),
# updated by paperflow-gmb (orphan-resolution tiers).
#
# Originally asserted the doctor's orphan_task_count gate FAILS on a store
# with > 25% rootless tasks. After paperflow-gmb the importer's 2-tier
# resolution (dep-edge inference + synthetic imported-legacy bucket) parents
# every recoverable/legacy task, so the SAME synthetic store now resolves to
# 0 residual orphans → orphan_task_count.status=pass. This test now asserts
# that post-fix contract: pre-convention orphans no longer trip the gate.
# (The doctor's FAIL-gate mechanics remain covered by
# tests/doctor-ensure-tasks-gate.sh, which forces a fail row directly.)
#
# Doesn't require barkpark — the orphan check runs in dry-run mode
# (no curl traffic). Other checks may warn/fail depending on environment;
# we only assert the orphan_task_count row here.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO/bin/paperflow-doctor"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

TMPDIR_T="$(mktemp -d -t pf-ensure-orphans.XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Store: 1 goal + 1 phase + 2 in-phase tasks + 3 formerly-orphan tasks.
#   o1 — dep-edge blocks→phase  → tier-1 recovers.
#   o2 — dep-edge parent-child→phase → tier-1 recovers (legacy convention).
#   o3 — no usable edge → tier-2 parents to synthetic phase.
# All three end up parented; the doctor must report 0 residual orphans.
STORE_DIR="$TMPDIR_T/.beads"
mkdir -p "$STORE_DIR"
cat > "$STORE_DIR/issues.jsonl" <<'EOF'
{"_type":"issue","id":"bd-orph-g","title":"G","status":"open","priority":2,"issue_type":"epic","labels":["goal-orph","kind:goal"]}
{"_type":"issue","id":"bd-orph-p","title":"build","status":"open","priority":2,"issue_type":"task","labels":["goal-orph","kind:phase","phase-build"]}
{"_type":"issue","id":"bd-orph-t1","title":"T1","status":"open","priority":2,"issue_type":"task","labels":["goal-orph","phase-build"]}
{"_type":"issue","id":"bd-orph-t2","title":"T2","status":"open","priority":2,"issue_type":"task","labels":["goal-orph","phase-build"]}
{"_type":"issue","id":"bd-orph-o1","title":"O1","status":"open","priority":2,"issue_type":"task","labels":["goal-orph"],"dependencies":[{"issue_id":"bd-orph-o1","depends_on_id":"bd-orph-p","type":"blocks","created_at":"2026-05-25T00:00:00Z","created_by":"t","metadata":"{}"}]}
{"_type":"issue","id":"bd-orph-o2","title":"O2","status":"open","priority":2,"issue_type":"task","labels":["goal-orph"],"dependencies":[{"issue_id":"bd-orph-o2","depends_on_id":"bd-orph-p","type":"parent-child","created_at":"2026-05-25T00:00:00Z","created_by":"t","metadata":"{}"}]}
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

orph_status="$(printf '%s' "$out" | jq -r '.ensure_tasks.orphan_task_count.status' 2>/dev/null)"
orph_count="$(printf '%s' "$out" | jq -r '.ensure_tasks.orphan_task_count.count' 2>/dev/null)"
orph_pct="$(printf '%s' "$out" | jq -r '.ensure_tasks.orphan_task_count.percent' 2>/dev/null)"

# Post-fix: 0 residual orphans → status=pass.
if [ "$orph_status" = "pass" ]; then
    green "PASS: orphan_task_count.status=pass (resolution tiers cleared all orphans)"
else
    red "FAIL: orphan_task_count.status=$orph_status (expected pass)"
    printf '  detail: %s\n' "$(printf '%s' "$out" | jq -c '.ensure_tasks.orphan_task_count')"
    fail=1
fi

if [ "$orph_count" = "0" ]; then
    green "PASS: count=0 — no residual rootless tasks"
else
    red "FAIL: count=$orph_count (expected 0)"; fail=1
fi

# The underlying importer must show tier-1=2 (blocks + parent-child) and
# tier-2=1 (the truly-rootless o3) — assert via a direct importer dry-run.
imp="$(PAPERFLOW_MIRROR_GOALS=0 bash "$REPO/bin/paperflow-import-bd" --store "$STORE_DIR/issues.jsonl" 2>&1)"
if printf '%s\n' "$imp" | grep -q 'recovered-via-dep-edge: 2'; then
    green "PASS: tier-1 recovered 2 (blocks + parent-child edges)"
else
    red "FAIL: tier-1 dep-edge recovery count wrong"
    printf '%s\n' "$imp" | grep 'recovered-via-dep-edge' || true
    fail=1
fi
if printf '%s\n' "$imp" | grep -q 'parented-to-synthetic: 1'; then
    green "PASS: tier-2 parented 1 truly-rootless task to synthetic phase"
else
    red "FAIL: tier-2 synthetic count wrong"
    printf '%s\n' "$imp" | grep 'parented-to-synthetic' || true
    fail=1
fi

# rc note: ensure-tasks may still exit 2 from unrelated env checks
# (barkpark unreachable, dual-write off). We do not assert rc here — the
# orphan row is the contract under test. Reference rc to satisfy set -u.
: "$rc" "$orph_pct"

exit "$fail"
