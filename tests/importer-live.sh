#!/usr/bin/env bash
# tests/importer-live.sh — W7d step 1 (paperflow-18d).
# Live test against a real barkpark on :4001. SKIPs cleanly when barkpark
# is unreachable (which is the daily-driver state — barkpark isn't always
# running). Follows the existing skip-if-down convention from
# doc-meta-mirror-up.sh + active-scope-validate-up.sh.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPORTER="$REPO/bin/paperflow-import-bd"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

BP_URL="${PAPERFLOW_BARKPARK_URL:-http://localhost:4001}"
probe="$(curl -s -m 2 -o /dev/null -w '%{http_code}' \
    "$BP_URL/v1/tasks" 2>/dev/null || echo 000)"
case "$probe" in
    2*|4*) green "barkpark reachable at $BP_URL (http $probe) — proceeding" ;;
    *)     yellow "SKIP: barkpark not reachable at $BP_URL (probe $probe)"; exit 0 ;;
esac

export PAPERFLOW_MIRROR_GOALS=1
export PAPERFLOW_BARKPARK_URL="$BP_URL"

# Synthetic 3-row file with unique ids to avoid colliding with real data.
NONCE="$(date +%s)"
TMPDIR_T="$(mktemp -d -t pf-import-live.XXXXXX)"
JSONL="$TMPDIR_T/issues.jsonl"
GID="bd-live-g-$NONCE"
PID="bd-live-p-$NONCE"
TID="bd-live-t-$NONCE"
cat > "$JSONL" <<EOF
{"_type":"issue","id":"$GID","title":"Live test goal $NONCE","status":"open","priority":2,"issue_type":"epic","labels":["goal-live-$NONCE","kind:goal"]}
{"_type":"issue","id":"$PID","title":"build","status":"open","priority":2,"issue_type":"task","labels":["goal-live-$NONCE","kind:phase","phase-build"]}
{"_type":"issue","id":"$TID","title":"Live task $NONCE","description":"end-to-end","status":"open","priority":2,"issue_type":"task","labels":["goal-live-$NONCE","phase-build"]}
EOF

fail=0

# First apply — expect 3 imported.
out1="$(bash "$IMPORTER" --store "$JSONL" --apply --verbose 2>&1)"
rc1=$?
if [ "$rc1" -eq 0 ] && printf '%s\n' "$out1" | grep -q 'imported: 3 / failed: 0'; then
    green "PASS: first apply imported 3 docs"
else
    red "FAIL: first apply did not import 3 (rc=$rc1)"
    printf '%s\n' "$out1"
    fail=1
fi

# Second apply — expect 3 already-in.
out2="$(bash "$IMPORTER" --store "$JSONL" --apply --verbose 2>&1)"
rc2=$?
if [ "$rc2" -eq 0 ] && printf '%s\n' "$out2" | grep -q 'already-in-barkpark: 3'; then
    green "PASS: re-run reports already-in-barkpark: 3 (idempotent)"
else
    red "FAIL: re-run not idempotent"
    printf '%s\n' "$out2"
    fail=1
fi

rm -rf "$TMPDIR_T"
exit "$fail"
