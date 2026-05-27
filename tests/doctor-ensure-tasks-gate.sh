#!/usr/bin/env bash
# tests/doctor-ensure-tasks-gate.sh — W7d step 2 (paperflow-5ki).
#
# Asserts --gate-for-flip strict mode: when any check returns warn OR
# fail, exit code is 2. Specifically, we synthesise a state where:
#   * dual_write_enabled = warn (PAPERFLOW_MIRROR_GOALS unset)
#   * everything else = pass-ish
# and prove that the standard mode would be exit 0 (warns ok), but
# --gate-for-flip lifts the bar so exit becomes 2.
#
# w7-16 (atomic flip) is the sole intended caller of --gate-for-flip —
# this test pins the contract.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO/bin/paperflow-doctor"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

TMPDIR_T="$(mktemp -d -t pf-ensure-gate.XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Zero-orphan store (so only dual_write_enabled is the warn).
STORE_DIR="$TMPDIR_T/.beads"
mkdir -p "$STORE_DIR"
cat > "$STORE_DIR/issues.jsonl" <<'EOF'
{"_type":"issue","id":"bd-gate-g","title":"G","status":"open","priority":2,"issue_type":"epic","labels":["goal-gate","kind:goal"]}
{"_type":"issue","id":"bd-gate-p","title":"build","status":"open","priority":2,"issue_type":"task","labels":["goal-gate","kind:phase","phase-build"]}
{"_type":"issue","id":"bd-gate-t1","title":"T1","status":"open","priority":2,"issue_type":"task","labels":["goal-gate","phase-build"]}
EOF

WRAPPER_BIN="$TMPDIR_T/bin"
mkdir -p "$WRAPPER_BIN"
cat > "$WRAPPER_BIN/paperflow-import-bd" <<EOF
#!/usr/bin/env bash
exec "$REPO/bin/paperflow-import-bd" --store "$STORE_DIR/issues.jsonl" "\$@"
EOF
chmod +x "$WRAPPER_BIN/paperflow-import-bd"

fail=0

# ─── 1. Without --gate-for-flip: warns must be tolerated. ──────────────
out_default="$(env -u PAPERFLOW_MIRROR_GOALS PATH="$WRAPPER_BIN:$PATH" \
    bash "$DOCTOR" --ensure-tasks 2>&1)"
rc_default=$?

any_fail="$(printf '%s' "$out_default" | jq -r '[.ensure_tasks[] | select(.status=="fail")] | length' 2>/dev/null)"
any_warn="$(printf '%s' "$out_default" | jq -r '[.ensure_tasks[] | select(.status=="warn")] | length' 2>/dev/null)"

if [ "${any_warn:-0}" -gt 0 ] && [ "${any_fail:-0}" -eq 0 ]; then
    # The test environment we control yields warn-but-no-fail.
    if [ "$rc_default" -eq 0 ]; then
        green "PASS: warns-only without --gate-for-flip → exit 0"
    else
        red "FAIL: warns-only but default-mode exit=$rc_default (expected 0)"
        printf '%s\n' "$out_default"
        fail=1
    fi
elif [ "${any_fail:-0}" -gt 0 ]; then
    # CI may have unrelated fail rows we can't suppress (e.g. barkpark
    # unreachable). In that case both modes exit 2 and the delta is
    # untestable — skip the comparison rather than report a false fail.
    printf 'NOTE: %d unrelated fail rows in env — default-mode delta untestable\n' "$any_fail"
else
    printf 'NOTE: no warn AND no fail — environment too clean to test gate delta\n'
fi

# ─── 2. With --gate-for-flip: warns lift to fails. ─────────────────────
out_gate="$(env -u PAPERFLOW_MIRROR_GOALS PATH="$WRAPPER_BIN:$PATH" \
    bash "$DOCTOR" --ensure-tasks --gate-for-flip 2>&1)"
rc_gate=$?

if [ "${any_warn:-0}" -gt 0 ] || [ "${any_fail:-0}" -gt 0 ]; then
    if [ "$rc_gate" -eq 2 ]; then
        green "PASS: with --gate-for-flip and any warn/fail → exit 2"
    else
        red "FAIL: --gate-for-flip exit=$rc_gate (expected 2 with warn/fail present)"
        printf '%s\n' "$out_gate"
        fail=1
    fi
fi

# gate_for_flip is reflected in the JSON envelope.
gate_field="$(printf '%s' "$out_gate" | jq -r '.gate_for_flip' 2>/dev/null)"
if [ "$gate_field" = "true" ]; then
    green "PASS: ensure_tasks.gate_for_flip=true"
else
    red "FAIL: gate_for_flip=$gate_field (expected true)"
    fail=1
fi

gate_field_default="$(printf '%s' "$out_default" | jq -r '.gate_for_flip' 2>/dev/null)"
if [ "$gate_field_default" = "false" ]; then
    green "PASS: ensure_tasks.gate_for_flip=false in default mode"
else
    red "FAIL: default-mode gate_for_flip=$gate_field_default (expected false)"
    fail=1
fi

exit "$fail"
