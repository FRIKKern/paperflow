#!/usr/bin/env bash
# tests/importer-classification.sh — W7d step 1 (paperflow-18d).
# Synthetic .beads/issues.jsonl with one of each shape (goal, phase, task,
# orphan-task). Asserts the importer's classifier emits the right kind +
# correctly-resolved parent_id from labels alone, no network.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPORTER="$REPO/bin/paperflow-import-bd"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

TMPDIR_T="$(mktemp -d -t pf-import-class.XXXXXX)"
JSONL="$TMPDIR_T/issues.jsonl"
cat > "$JSONL" <<'EOF'
{"_type":"issue","id":"bd-test-goal","title":"Goal under test","status":"open","priority":2,"issue_type":"epic","labels":["goal-test-slug","kind:goal"]}
{"_type":"issue","id":"bd-test-phase","title":"Build phase","status":"open","priority":2,"issue_type":"task","labels":["goal-test-slug","kind:phase","phase-build"]}
{"_type":"issue","id":"bd-test-task","title":"Concrete task","description":"Wired through.","status":"in_progress","priority":1,"issue_type":"task","labels":["goal-test-slug","phase-build"]}
{"_type":"issue","id":"bd-test-orphan","title":"Orphan no-phase task","status":"closed","priority":3,"issue_type":"task","labels":["goal-test-slug"]}
EOF

# Dry-run; capture stdout. PAPERFLOW_MIRROR_GOALS unset → no network probes.
out="$(bash "$IMPORTER" --store "$JSONL" --verbose 2>&1)" || {
    red "FAIL: importer exited non-zero on dry-run"
    printf '%s\n' "$out"
    rm -rf "$TMPDIR_T"
    exit 1
}

fail=0

# 1. Goal classified as goal, no parent.
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-test-goal as goal parent=<none>'; then
    green "PASS: goal row classified correctly with empty parent"
else
    red "FAIL: goal row mis-classified"
    fail=1
fi

# 2. Phase classified as phase, parent = bd-test-goal.
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-test-phase as phase parent=bd-test-goal'; then
    green "PASS: phase row resolves parent goal via shared goal-<slug> label"
else
    red "FAIL: phase row parent mis-resolved"
    fail=1
fi

# 3. Task classified as task, parent = bd-test-phase.
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-test-task as task parent=bd-test-phase'; then
    green "PASS: task row resolves parent phase via (goal-,phase-) label tuple"
else
    red "FAIL: task row parent mis-resolved"
    fail=1
fi

# 4. Orphan task classified as task with empty parent (NOT dropped).
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-test-orphan as task parent=<none>'; then
    green "PASS: orphan task emitted with empty parent (not dropped)"
else
    red "FAIL: orphan task either dropped or mis-classified"
    fail=1
fi

# 5. Classification summary shows G=1 P=1 T=2 orphan=1.
if printf '%s\n' "$out" | grep -q 'classified: G=1 P=1 T=2 (orphan=1)'; then
    green "PASS: classification summary correct"
else
    red "FAIL: classification summary wrong"
    printf '%s\n' "$out" | grep -E 'classified|would-import' || true
    fail=1
fi

rm -rf "$TMPDIR_T"
exit "$fail"
