#!/usr/bin/env bash
# tests/barkpark-event-on-save.sh — dry-run the Barkpark mirror seam added to
# hooks/event-on-save.sh (convergence W2-D, masterplan Figure 5 S2 / Figure 6).
#
# The Barkpark ingest endpoint + LiveView do not exist yet (a later barkpark
# unit builds them), so this exercises the seam with the network STUBBED via
# the hook's documented PAPERFLOW_DRYRUN=1 switch — which echoes the curl
# target + the open target to ~/.paperflow/barkpark-mirror.log instead of
# touching the network or the browser.
#
# Three cases:
#   ENABLED  — BARKPARK_INGEST_URL set. Assert the dry-run log shows
#              (a) extract-body produced a non-empty body (dryrun-post emitted),
#              (b) the POST targets the configured ingest URL,
#              (c) the opened URL is the Barkpark LiveView URL for the slug.
#   ENABLED-VIA-FILE — no env var, but ~/.paperflow/barkpark.env present.
#              Assert the seam sources the file and still mirrors.
#   DISABLED — neither signal present. Assert the Barkpark block is a complete
#              no-op (no mirror log written at all) — the original bridge-POST
#              path is untouched, no regression.
#
# Also asserts auto-open-doc.sh bows out when Barkpark is enabled (the
# "INSTEAD of cmux goto-reload" contract) and runs its normal path otherwise.
#
# Exit 0 iff every assertion passes.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/hooks/event-on-save.sh"
AUTO_OPEN="$REPO/hooks/auto-open-doc.sh"
EXTRACT="$REPO/bin/paperflow-extract-body"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

[ -x "$HOOK" ]    || { red "FAIL: missing/!x hook at $HOOK"; exit 2; }
[ -f "$EXTRACT" ] || { red "FAIL: missing extract-body at $EXTRACT"; exit 2; }

FAILS=0
assert_contains() { # haystack-file needle label
  if /usr/bin/grep -qF -- "$2" "$1" 2>/dev/null; then
    green "  ok: $3"
  else
    red   "  FAIL: $3 (looked for: $2)"
    FAILS=$((FAILS + 1))
  fi
}
assert_absent() { # file label
  if [ ! -s "$1" ]; then
    green "  ok: $2"
  else
    red   "  FAIL: $2 (file unexpectedly present/non-empty: $1)"
    FAILS=$((FAILS + 1))
  fi
}

# Build an isolated sandbox: its own HOME (so the real ~/.paperflow can't leak
# in), its own docs tree holding one realistic paperflow doc with a doc.js tail
# the extractor must strip.
SANDBOX="$(mktemp -d)" || { red "FAIL: cannot mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

DOCS="$SANDBOX/docs/paperflow/specs"
mkdir -p "$DOCS" "$SANDBOX/.paperflow"
DOC="$DOCS/2026-05-23-sample.html"
SLUG="2026-05-23-sample"
cat > "$DOC" <<'HTML'
<!doctype html><html><head><title>Sample</title></head>
<body>
<h1>Hello Barkpark</h1>
<p>Article body that must survive extraction.</p>
<script>window.CLAUDE_TARGET = {"x":1}; window.DOC_PATH = "2026-05-23-sample.html";</script>
<script src="/paperflow/_lib/doc.js"></script>
</body></html>
HTML

# The hook reads the file path from JSON on stdin.
PAYLOAD="$(/usr/bin/env jq -nc --arg fp "$DOC" '{tool_input:{file_path:$fp}, session_id:"test-session"}')"

run_hook() { # extra env assignments passed as KEY=VAL ... ; PAYLOAD on stdin
  printf '%s' "$PAYLOAD" | env -i \
    HOME="$SANDBOX" PATH="$PATH" \
    PAPERFLOW_DRYRUN=1 \
    "$@" \
    /usr/bin/env bash "$HOOK" 2>/dev/null
}

MIRROR_LOG="$SANDBOX/.paperflow/barkpark-mirror.log"
INGEST_URL="http://127.0.0.1:4000/api/papers/ingest"
LIVEVIEW_URL="http://127.0.0.1:4000/papers/$SLUG"

echo "== Case ENABLED (BARKPARK_INGEST_URL set) =="
rm -f "$MIRROR_LOG"
run_hook BARKPARK_INGEST_URL="$INGEST_URL" BARKPARK_INGEST_TOKEN="tok"
# (a) extract-body produced a non-empty body → dryrun-post line emitted.
assert_contains "$MIRROR_LOG" '"event":"dryrun-post"' "(a) extract-body ran, body non-empty"
# Body really was extracted (the tail must be gone, the article must be there):
BODY_OUT="$("$EXTRACT" "$DOC")"
case "$BODY_OUT" in
  *"Hello Barkpark"*) green "  ok: extracted body contains the article" ;;
  *) red "  FAIL: extracted body missing the article"; FAILS=$((FAILS+1)) ;;
esac
case "$BODY_OUT" in
  *CLAUDE_TARGET*|*doc.js*) red "  FAIL: extracted body still has the script tail"; FAILS=$((FAILS+1)) ;;
  *) green "  ok: extracted body has no script tail" ;;
esac
# (b) POST targets the configured ingest URL.
assert_contains "$MIRROR_LOG" "POST $INGEST_URL" "(b) POST targets configured ingest URL"
# (c) opened URL is the Barkpark LiveView URL.
assert_contains "$MIRROR_LOG" "open $LIVEVIEW_URL" "(c) opened URL is the LiveView URL"

echo "== Case ENABLED-VIA-FILE (~/.paperflow/barkpark.env) =="
rm -f "$MIRROR_LOG"
cat > "$SANDBOX/.paperflow/barkpark.env" <<EOF
BARKPARK_INGEST_URL=$INGEST_URL
BARKPARK_INGEST_TOKEN=barkpark-dev-token
EOF
run_hook
assert_contains "$MIRROR_LOG" "POST $INGEST_URL" "sources env file + POSTs to configured URL"
assert_contains "$MIRROR_LOG" "open $LIVEVIEW_URL" "sources env file + opens LiveView URL"
rm -f "$SANDBOX/.paperflow/barkpark.env"

echo "== Case DISABLED (no signal) =="
rm -f "$MIRROR_LOG"
run_hook
# Barkpark block must be a complete no-op: no mirror log at all.
assert_absent "$MIRROR_LOG" "Barkpark block is a no-op when disabled (no mirror log)"

echo "== auto-open-doc.sh: 'INSTEAD of cmux goto-reload' contract =="
# When Barkpark is enabled, auto-open must bow out BEFORE any dispatch — assert
# its auto-open.log gets no new entry. We can't drive cmux here, so we assert
# the early-exit by checking no auto-open.log line is written for our doc.
AO_LOG="$SANDBOX/.paperflow/auto-open.log"
rm -f "$AO_LOG"
printf '%s' "$PAYLOAD" | env -i HOME="$SANDBOX" PATH="$PATH" \
  BARKPARK_INGEST_URL="$INGEST_URL" \
  /usr/bin/env bash "$AUTO_OPEN" 2>/dev/null
assert_absent "$AO_LOG" "auto-open bows out (no dispatch log) when Barkpark enabled"

# When Barkpark is disabled, auto-open should reach its dispatch+log path. On a
# non-cmux host it falls back to /usr/bin/open and writes an auto-open.log line.
rm -f "$AO_LOG"
printf '%s' "$PAYLOAD" | env -i HOME="$SANDBOX" PATH="$PATH" \
  /usr/bin/env bash "$AUTO_OPEN" 2>/dev/null
if [ -s "$AO_LOG" ]; then
  green "  ok: auto-open runs its normal path when Barkpark disabled"
else
  red   "  FAIL: auto-open wrote no log when Barkpark disabled (path changed?)"
  FAILS=$((FAILS + 1))
fi

echo
if [ "$FAILS" -eq 0 ]; then
  green "ALL PASS"
  exit 0
else
  red "$FAILS assertion(s) FAILED"
  exit 1
fi
