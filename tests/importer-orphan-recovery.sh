#!/usr/bin/env bash
# tests/importer-orphan-recovery.sh — paperflow-gmb (W7d).
# Synthetic .beads/issues.jsonl exercising the 2-tier orphan resolution:
#   * 1 task with a phase- label  → resolved by the LABEL tier.
#   * 1 orphan task with NO phase- label but a dependencies[] blocks-edge
#     pointing at a known phase id → recovered by TIER-1 (dep-edge).
#   * 1 orphan task with NO phase- label and NO usable dep edge → parented by
#     TIER-2 to the synthetic imported-unparented phase.
#   * 1 orphan task whose only dep edge points at a GOAL (not a phase) → must
#     NOT be adopted by tier-1 (goals aren't task parents); falls to tier-2.
# Assert: tier-1 recovers exactly 1, tier-2 parents exactly 2, final
# orphan (still rootless) = 0. No network (MIRROR env unset → dry-run).

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPORTER="$REPO/bin/paperflow-import-bd"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

TMPDIR_T="$(mktemp -d -t pf-import-orphan.XXXXXX)"
JSONL="$TMPDIR_T/issues.jsonl"
cat > "$JSONL" <<'EOF'
{"_type":"issue","id":"bd-g1","title":"Goal one","status":"open","priority":2,"issue_type":"epic","labels":["goal-slug-one","kind:goal"]}
{"_type":"issue","id":"bd-p1","title":"Build phase","status":"open","priority":2,"issue_type":"task","labels":["goal-slug-one","kind:phase","phase-build"]}
{"_type":"issue","id":"bd-label-task","title":"Label-resolved task","status":"open","priority":2,"issue_type":"task","labels":["goal-slug-one","phase-build"]}
{"_type":"issue","id":"bd-dep-task","title":"Dep-edge orphan","status":"open","priority":2,"issue_type":"task","labels":["goal-slug-one"],"dependencies":[{"issue_id":"bd-dep-task","depends_on_id":"bd-p1","type":"blocks","created_at":"2026-05-25T00:00:00Z","created_by":"test","metadata":"{}"}]}
{"_type":"issue","id":"bd-rootless-task","title":"Truly rootless","status":"closed","priority":3,"issue_type":"task","labels":["goal-slug-one"]}
{"_type":"issue","id":"bd-goaldep-task","title":"Dep-to-goal only","status":"open","priority":2,"issue_type":"task","labels":["goal-slug-one"],"dependencies":[{"issue_id":"bd-goaldep-task","depends_on_id":"bd-g1","type":"blocks","created_at":"2026-05-25T00:00:00Z","created_by":"test","metadata":"{}"}]}
EOF

out="$(bash "$IMPORTER" --store "$JSONL" 2>&1)" || {
    red "FAIL: importer exited non-zero on dry-run"
    printf '%s\n' "$out"
    rm -rf "$TMPDIR_T"
    exit 1
}

fail=0

# 1. Label-tier task → parent = bd-p1 via=label.
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-label-task as task parent=bd-p1 lifecycle=open via=label'; then
    green "PASS: label-tier task resolves to phase via (goal-,phase-) labels"
else
    red "FAIL: label-tier task mis-resolved"
    printf '%s\n' "$out" | grep 'bd-label-task' || true
    fail=1
fi

# 2. Tier-1 dep-edge task → parent = bd-p1 via=dep-edge.
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-dep-task as task parent=bd-p1 lifecycle=open via=dep-edge'; then
    green "PASS: tier-1 recovers orphan via dependencies[] blocks-edge to phase"
else
    red "FAIL: tier-1 dep-edge recovery failed"
    printf '%s\n' "$out" | grep 'bd-dep-task' || true
    fail=1
fi

# 3. Genuinely-rootless task → tier-2 synthetic phase.
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-rootless-task as task parent=bd-imported-unparented-phase lifecycle=done via=synthetic'; then
    green "PASS: tier-2 parents truly-rootless task to synthetic phase"
else
    red "FAIL: tier-2 did not parent rootless task to synthetic phase"
    printf '%s\n' "$out" | grep 'bd-rootless-task' || true
    fail=1
fi

# 4. Dep-to-GOAL-only task is NOT adopted by tier-1 (goals aren't task parents)
#    → falls to tier-2 synthetic phase.
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-goaldep-task as task parent=bd-imported-unparented-phase lifecycle=open via=synthetic'; then
    green "PASS: dep-edge to goal is rejected by tier-1, falls to tier-2"
else
    red "FAIL: dep-to-goal task mis-handled (should fall to tier-2, not adopt the goal)"
    printf '%s\n' "$out" | grep 'bd-goaldep-task' || true
    fail=1
fi

# 5. Recovery counters: dep-edge=1, synthetic=2.
if printf '%s\n' "$out" | grep -q 'recovered-via-dep-edge: 1'; then
    green "PASS: recovered-via-dep-edge = 1"
else
    red "FAIL: recovered-via-dep-edge count wrong"
    printf '%s\n' "$out" | grep 'recovered-via-dep-edge' || true
    fail=1
fi
if printf '%s\n' "$out" | grep -q 'parented-to-synthetic: 2'; then
    green "PASS: parented-to-synthetic = 2 (rootless + dep-to-goal)"
else
    red "FAIL: parented-to-synthetic count wrong"
    printf '%s\n' "$out" | grep 'parented-to-synthetic' || true
    fail=1
fi

# 6. Final orphan (still rootless) = 0 — the whole point.
if printf '%s\n' "$out" | grep -q 'orphan (still rootless): 0'; then
    green "PASS: final orphan count = 0"
else
    red "FAIL: residual orphans remain"
    printf '%s\n' "$out" | grep -E 'orphan|classified' || true
    fail=1
fi

# 7. Soft-spot #2 (slug carry): synthetic goal carries goal_slug imported-legacy
#    AND the real goal still classifies. We assert the synthetic goal id scheme.
if printf '%s\n' "$out" | grep -q 'WOULD-POST: bd-imported-legacy-goal as goal parent=<none> lifecycle=open via=synthetic'; then
    green "PASS: synthetic imported-legacy goal emitted at top level"
else
    red "FAIL: synthetic goal id scheme wrong"
    printf '%s\n' "$out" | grep 'imported-legacy' || true
    fail=1
fi

rm -rf "$TMPDIR_T"
exit "$fail"
