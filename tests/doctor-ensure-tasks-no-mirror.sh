#!/usr/bin/env bash
# tests/doctor-ensure-tasks-no-mirror.sh — W7d step 2 (paperflow-5ki).
#
# Asserts that with PAPERFLOW_MIRROR_GOALS unset (daily-driver default),
# the dual_write_enabled check returns warn — NOT fail. The overall
# result is NOT a fail (exit 0 unless another check independently fails).
#
# This is the daily-driver-doesn't-break guarantee: doctor's new
# subcommand surfaces the migration prerequisite as a warning, never
# forces it as a hard fail unless --gate-for-flip is also passed.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO/bin/paperflow-doctor"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

TMPDIR_T="$(mktemp -d -t pf-ensure-nomirror.XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Zero-orphan synthetic store so orphan_task_count doesn't fail and
# muddy the assertion. We only care about dual_write_enabled here.
STORE_DIR="$TMPDIR_T/.beads"
mkdir -p "$STORE_DIR"
cat > "$STORE_DIR/issues.jsonl" <<'EOF'
{"_type":"issue","id":"bd-nm-g","title":"G","status":"open","priority":2,"issue_type":"epic","labels":["goal-nm","kind:goal"]}
{"_type":"issue","id":"bd-nm-p","title":"build","status":"open","priority":2,"issue_type":"task","labels":["goal-nm","kind:phase","phase-build"]}
{"_type":"issue","id":"bd-nm-t1","title":"T1","status":"open","priority":2,"issue_type":"task","labels":["goal-nm","phase-build"]}
EOF

WRAPPER_BIN="$TMPDIR_T/bin"
mkdir -p "$WRAPPER_BIN"
cat > "$WRAPPER_BIN/paperflow-import-bd" <<EOF
#!/usr/bin/env bash
exec "$REPO/bin/paperflow-import-bd" --store "$STORE_DIR/issues.jsonl" "\$@"
EOF
chmod +x "$WRAPPER_BIN/paperflow-import-bd"

# Explicitly clear PAPERFLOW_MIRROR_GOALS via env -i style.
out="$(PATH="$WRAPPER_BIN:$PATH" unset PAPERFLOW_MIRROR_GOALS 2>/dev/null; \
       env -u PAPERFLOW_MIRROR_GOALS PATH="$WRAPPER_BIN:$PATH" bash "$DOCTOR" --ensure-tasks 2>&1)"
rc=$?

fail=0

# dual_write_enabled must be 'warn'.
dw_status="$(printf '%s' "$out" | jq -r '.ensure_tasks.dual_write_enabled.status' 2>/dev/null)"
if [ "$dw_status" = "warn" ]; then
    green "PASS: dual_write_enabled.status=warn"
else
    red "FAIL: dual_write_enabled.status=$dw_status (expected warn)"
    printf '  detail: %s\n' "$(printf '%s' "$out" | jq -c '.ensure_tasks.dual_write_enabled')"
    fail=1
fi

# Repair command must be the export line — actionable for the user.
dw_repair="$(printf '%s' "$out" | jq -r '.ensure_tasks.dual_write_enabled.repair_command' 2>/dev/null)"
if [ "$dw_repair" = "export PAPERFLOW_MIRROR_GOALS=1" ]; then
    green "PASS: repair_command suggests the export"
else
    red "FAIL: repair_command='$dw_repair'"
    fail=1
fi

# Overall is not-fail in default mode (warns ok).
if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
    # 0 is what we expect when other checks all pass; 2 is acceptable
    # only if a non-dual-write check independently failed (we don't
    # control the broader environment in CI). Either way the dual-write
    # warning must NOT be the sole cause.
    if [ "$rc" -eq 0 ]; then
        green "PASS: exit 0 (warns alone do not fail)"
    else
        # 2 must come from another check failing, not dual_write.
        any_fail="$(printf '%s' "$out" | jq -r '[.ensure_tasks[] | select(.status=="fail")] | length' 2>/dev/null)"
        if [ "${any_fail:-0}" -gt 0 ]; then
            green "PASS: exit 2 but from a different check (count=$any_fail); dual_write still warn-only"
        else
            red "FAIL: exit 2 with no failing check — dual_write warn is being mis-counted as fail"
            fail=1
        fi
    fi
else
    red "FAIL: unexpected exit $rc"
    printf '%s\n' "$out"
    fail=1
fi

exit "$fail"
