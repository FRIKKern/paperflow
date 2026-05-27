#!/usr/bin/env bash
# tests/active-scope-validate-no-mirror.sh — daily-driver invariant
# for W7c step 2. With PAPERFLOW_MIRROR_GOALS unset, --validate is a
# silent no-op (exit 0) regardless of pointer state — even when no
# pointer is set.
#
# Exit 0 on pass, 1 on fail.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/bin/paperflow-active-scope"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

TMP="$(mktemp -d -t pf-validate-nm.XXXXXX)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export PAPERFLOW_DIR="$TMP"
unset PAPERFLOW_MIRROR_GOALS
unset PAPERFLOW_BARKPARK_URL
unset CMUX_WORKSPACE_ID CMUX_SURFACE_REF CLAUDE_SESSION_ID

# 1. No pointer set → still exit 0 (mirror disabled = no-op).
out="$(bash "$SCRIPT" --validate goal 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: --validate goal with no env, no pointer → rc=$rc (expected 0)"
    printf '  output: %s\n' "$out"
    exit 1
fi
[ -z "$out" ] || { red "FAIL: --validate emitted output with mirror unset: $out"; exit 1; }
green "PASS: --validate goal no-env no-pointer → silent exit 0"

# 2. With a pointer set, same outcome.
bash "$SCRIPT" --write goal "paperflow-noop-$$" >/dev/null
out="$(bash "$SCRIPT" --validate goal 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: --validate goal with pointer + no env → rc=$rc"
    printf '  output: %s\n' "$out"
    exit 1
fi
[ -z "$out" ] || { red "FAIL: --validate emitted output with mirror unset: $out"; exit 1; }
green "PASS: --validate goal with pointer + no env → silent exit 0"

# 3. Phase symmetry.
bash "$SCRIPT" --write phase "paperflow-noop-$$.1" >/dev/null
out="$(bash "$SCRIPT" --validate phase 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    red "FAIL: --validate phase no-env → rc=$rc"
    exit 1
fi
green "PASS: --validate phase no-env → silent exit 0"

# 4. --write with no env must NOT touch a log (the mirror branch is gated).
LOG="$TMP/mirror.log"
export BARKPARK_MIRROR_LOG="$LOG"
bash "$SCRIPT" --write goal "paperflow-quiet-$$" >/dev/null 2>&1
if [ -s "$LOG" ]; then
    red "FAIL: mirror log touched by --write with mirror disabled"
    head -3 "$LOG"
    exit 1
fi
green "PASS: --write no-env leaves mirror log untouched"

green "─── active-scope-validate-no-mirror: ALL PASS ───"
exit 0
