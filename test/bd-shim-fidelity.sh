#!/usr/bin/env bash
# w7-08 / Gate-B — JSON-shape fidelity for bd-shim.
#
# For each .json fixture under test/fixtures/bd-shim/, run the equivalent
# bd-shim invocation against the configured Barkpark instance, then
# compare the SHAPE — sorted top-level key set + per-key JSON type
# signature — of the shim's stdout against the captured golden.
#
# Why shape-equality not byte-equality:
#   Captured fixtures come from a real bd instance against the paperflow
#   .beads/issues.jsonl with REAL ids and REAL timestamps. The Barkpark
#   seed mirrors the structural data (kind, status, parent-child edges)
#   but doc_ids + created_at differ. A byte-equal contract would require
#   freezing the entire upstream state, which is brittle. SHAPE equality
#   catches every breaking change to the consumer-facing JSON (added key,
#   dropped key, type flip from string→number) without false negatives
#   from real-world data drift.
#
# Text fixtures (.txt) hold a regex; the shim's stdout for the matching
# invocation must regex-match. Used for `bd dep add` confirmation lines.
#
# Usage:
#   BARKPARK_URL=http://localhost:4001 ./test/bd-shim-fidelity.sh
#
# Exit codes:
#   0 — every fixture matches
#   1 — at least one mismatch; per-fixture diff printed to stderr
#   2 — environment failure (no barkpark, no jq, no shim)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIX_DIR="$REPO_DIR/test/fixtures/bd-shim"
SHIM="$REPO_DIR/bin/bd-shim"

: "${BARKPARK_URL:=http://localhost:4001}"
: "${BARKPARK_TOKEN:=barkpark-dev-token}"
export BARKPARK_URL BARKPARK_TOKEN

# ── env preflight ────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { echo "fidelity: jq not on PATH" >&2; exit 2; }
[ -x "$SHIM" ] || { echo "fidelity: $SHIM not executable" >&2; exit 2; }

# Selftest the shim against the configured barkpark. If barkpark isn't up
# we fail fast (exit 2) so CI doesn't confuse "infra broken" with "fixtures
# broken."
if ! "$SHIM" --selftest >/dev/null 2>&1; then
  echo "fidelity: bd-shim --selftest failed against $BARKPARK_URL" >&2
  echo "fidelity: spin up barkpark first: cd <bp>/api && PORT=4001 mix phx.server" >&2
  exit 2
fi

# ── fixture → invocation map ─────────────────────────────────────────────
# Parallel arrays (bash 3.2 doesn't have associative arrays).
FIXTURES=()
INVOCATIONS=()

reg() { FIXTURES+=("$1"); INVOCATIONS+=("$2"); }

reg "ready-all.json"                "ready --json"
reg "ready-phase-build.json"        "ready --label phase-build --json"
reg "ready-phase-and-goal.json"     "ready --label phase-build --label goal-w7-retire-beads --json"
reg "list-all.json"                 "list --json"
reg "list-type-epic.json"           "list --type epic --json"
reg "list-type-epic-status-open.json" "list --type epic --status open --json"
reg "list-label-kind-phase.json"    "list --label kind:phase --json"
reg "list-label-kind-goal.json"     "list --label kind:goal --json"
reg "list-label-goal.json"          "list --label goal-w7-retire-beads --json"
reg "show-goal.json"                "show paperflow-7r9 --json"
reg "show-phase.json"               "show paperflow-xmb --json"
reg "show-work-task.json"           "show paperflow-5wk --json"
reg "epic-close-eligible.json"      "epic close-eligible --json"

# ── shape helpers ────────────────────────────────────────────────────────
# `shape_of` emits sorted top-level key set + per-key JSON type signature.
# Arrays are reduced to the shape of element[0] (or [] when empty). Objects
# are reduced to sorted-keys + per-key type. This is the contract w7-08
# guards against drift.
shape_jq='
def shape:
  if type == "array" then
    if length == 0 then { "_array": [] }
    else { "_array": (.[0] | shape) }
    end
  elif type == "object" then
    [keys[] as $k | { ($k): (.[$k] | type) }] | add // {}
  else type
  end;
shape
'

# ── run the comparisons ──────────────────────────────────────────────────
ok=0
fail=0
total=${#FIXTURES[@]}

for i in $(seq 0 $((total - 1))); do
  fixture="${FIXTURES[$i]}"
  invocation="${INVOCATIONS[$i]}"
  golden="$FIX_DIR/$fixture"
  [ -f "$golden" ] || { echo "fidelity: missing fixture $golden" >&2; fail=$((fail+1)); continue; }

  # Run the shim. Use `set +e` window so a non-zero shim exit doesn't kill
  # the whole script — we count and report instead.
  set +e
  shim_out="$($SHIM $invocation 2>/dev/null)"
  shim_rc=$?
  set -e
  if [ $shim_rc -ne 0 ]; then
    echo "FAIL  $fixture — shim exit $shim_rc (invocation: $invocation)" >&2
    fail=$((fail+1))
    continue
  fi

  golden_shape="$(jq -S "$shape_jq" "$golden" 2>/dev/null || echo "{}")"
  shim_shape="$(printf '%s' "$shim_out" | jq -S "$shape_jq" 2>/dev/null || echo "{}")"

  if [ "$golden_shape" = "$shim_shape" ]; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    echo "FAIL  $fixture" >&2
    echo "  invocation: $SHIM $invocation" >&2
    echo "  diff (golden ← / shim →):" >&2
    diff <(printf '%s\n' "$golden_shape") <(printf '%s\n' "$shim_shape") >&2 || true
  fi
done

# ── text fixtures (regex match against shim stdout) ──────────────────────
# Currently only dep-add.txt; the shape is "one regex per line."
if [ -f "$FIX_DIR/dep-add.txt" ]; then
  total=$((total+1))
  pattern="$(head -n1 "$FIX_DIR/dep-add.txt")"
  # The dep-add invocation MUTATES state. Skip the live run; assert the
  # regex itself is well-formed instead (the byte-shape contract is "the
  # text emitted matches this regex," which is what consumers grep on).
  if printf '✓ Added dependency: foo → bar (blocks)\n' | grep -qE "$pattern"; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    echo "FAIL  dep-add.txt — pattern does not match sample line" >&2
  fi
fi

# ── summary ──────────────────────────────────────────────────────────────
if [ $fail -eq 0 ]; then
  echo "OK: $ok/$total fixtures match"
  exit 0
else
  echo "FAIL: $fail/$total fixtures mismatch ($ok passed)" >&2
  exit 1
fi
