#!/usr/bin/env bash
# tests/importer-dry-run.sh — W7d step 1 (paperflow-18d).
# 5-row synthetic file. Asserts dry-run prints WOULD-POST for all 5, exits
# 0, and makes NO curl calls (verified via PATH override that shadows curl
# with a sentinel that touches a marker file).

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPORTER="$REPO/bin/paperflow-import-bd"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

TMPDIR_T="$(mktemp -d -t pf-import-dry.XXXXXX)"
JSONL="$TMPDIR_T/issues.jsonl"
cat > "$JSONL" <<'EOF'
{"_type":"issue","id":"bd-dry-g1","title":"Dry goal 1","status":"open","priority":2,"issue_type":"epic","labels":["goal-dry-1","kind:goal"]}
{"_type":"issue","id":"bd-dry-p1","title":"build","status":"open","priority":2,"issue_type":"task","labels":["goal-dry-1","kind:phase","phase-build"]}
{"_type":"issue","id":"bd-dry-t1","title":"Task one","status":"open","priority":2,"issue_type":"task","labels":["goal-dry-1","phase-build"]}
{"_type":"issue","id":"bd-dry-t2","title":"Task two","status":"in_progress","priority":1,"issue_type":"task","labels":["goal-dry-1","phase-build"]}
{"_type":"issue","id":"bd-dry-t3","title":"Task three","status":"closed","priority":3,"issue_type":"task","labels":["goal-dry-1","phase-build"]}
EOF

# Set up a sentinel curl shim — any invocation touches MARKER.
BIN_SHIM="$TMPDIR_T/bin"
mkdir -p "$BIN_SHIM"
MARKER="$TMPDIR_T/curl-was-called"
cat > "$BIN_SHIM/curl" <<EOF
#!/usr/bin/env bash
touch "$MARKER"
echo '{"transactionId":"shim"}'
exit 0
EOF
chmod +x "$BIN_SHIM/curl"

# Run dry-run with the shim ahead of /usr/bin/curl on PATH. MIRROR env vars
# left unset so the helper short-circuits before curl anyway — both layers
# of defense are wired.
out="$(PATH="$BIN_SHIM:$PATH" bash "$IMPORTER" --store "$JSONL" 2>&1)"
rc=$?

fail=0

if [ "$rc" -ne 0 ]; then
    red "FAIL: dry-run exit $rc (expected 0)"
    printf '%s\n' "$out"
    fail=1
else
    green "PASS: dry-run exit 0"
fi

n_would="$(printf '%s\n' "$out" | grep -c 'WOULD-POST:' || true)"
if [ "$n_would" -eq 5 ]; then
    green "PASS: 5 WOULD-POST lines emitted"
else
    red "FAIL: expected 5 WOULD-POST, got $n_would"
    printf '%s\n' "$out"
    fail=1
fi

if [ -f "$MARKER" ]; then
    red "FAIL: dry-run made a curl call — marker file exists"
    fail=1
else
    green "PASS: dry-run made zero curl calls"
fi

# --limit caps work too.
out2="$(PATH="$BIN_SHIM:$PATH" bash "$IMPORTER" --store "$JSONL" --limit 2 2>&1)"
n_would2="$(printf '%s\n' "$out2" | grep -c 'WOULD-POST:' || true)"
if [ "$n_would2" -eq 2 ]; then
    green "PASS: --limit 2 caps to 2 rows"
else
    red "FAIL: --limit 2 expected 2 WOULD-POST, got $n_would2"
    fail=1
fi

rm -rf "$TMPDIR_T"
exit "$fail"
