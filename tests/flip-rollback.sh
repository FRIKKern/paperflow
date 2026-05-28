#!/usr/bin/env bash
# tests/flip-rollback.sh — W7d step 4 (w7-16).
# Synthesizes a fake flip-rollback.env + a fake bd symlink + fake FROZEN
# markers in a sandbox, then:
#   (A) runs paperflow-flip-rollback --dry-run and asserts it WOULD remove the
#       symlink / restore hooksPath / remove markers but touches NOTHING;
#   (B) runs the real (non-dry) rollback against the SANDBOX and asserts the
#       symlink is gone, hooksPath restored, markers removed — all on sandbox
#       paths, never the real system.
# A safety check confirms the real paperflow repo's hooksPath is untouched.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RB="$REPO/bin/paperflow-flip-rollback"
SHIM_SRC="$REPO/bin/bd-shim"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

TMP="$(mktemp -d -t pf-flip-rb.XXXXXX)"
fail=0

SBOX_PF="$TMP/dot-paperflow"
SBOX_BIN="$TMP/local-bin"
SBOX_REPO_A="$TMP/repo-a"
SBOX_REPO_B="$TMP/repo-b"
mkdir -p "$SBOX_PF" "$SBOX_BIN" "$SBOX_REPO_A/.beads" "$SBOX_REPO_B/.beads"
git -C "$SBOX_REPO_A" init -q 2>/dev/null
git -C "$SBOX_REPO_B" init -q 2>/dev/null
# Simulate post-flip state: hooksPath is UNSET (flip unset it). Rollback must
# put it back to the recorded values.
WANT_A="$SBOX_REPO_A/.beads/hooks"
WANT_B="$SBOX_REPO_B/.beads/hooks"

# Fake bd symlink → bd-shim (what the flip created).
ln -snf "$SHIM_SRC" "$SBOX_BIN/bd"

# Fake FROZEN markers.
echo frozen > "$SBOX_REPO_A/.beads/FROZEN"
echo frozen > "$SBOX_REPO_B/.beads/FROZEN"

# repo_key mirrors the script: tr '/.' '__'
keyfor() { printf '%s' "$1" | tr '/.' '__'; }
RB_ENV="$SBOX_PF/flip-rollback.env"
{
    echo "ORIG_BD_PATH=/opt/homebrew/bin/bd"
    echo "BD_SYMLINK=$SBOX_BIN/bd"
    echo "HOOKS_$(keyfor "$SBOX_REPO_A")=$WANT_A"
    echo "HOOKS_$(keyfor "$SBOX_REPO_B")=$WANT_B"
} > "$RB_ENV"

REAL_HOOKS_BEFORE="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || echo '<unset>')"

COMMON_ENV() {
    PAPERFLOW_DIR="$SBOX_PF"
    PAPERFLOW_FLIP_ROLLBACK_ENV="$RB_ENV"
    PAPERFLOW_FLIP_REPOS="$SBOX_REPO_A $SBOX_REPO_B"
    export PAPERFLOW_DIR PAPERFLOW_FLIP_ROLLBACK_ENV PAPERFLOW_FLIP_REPOS
}
COMMON_ENV

# ── (A) DRY-RUN — must change nothing ──────────────────────────────────
dry="$(bash "$RB" --dry-run 2>&1)"
drc=$?
if [ "$drc" -eq 0 ]; then green "PASS: rollback --dry-run exit 0"; else red "FAIL: dry-run exit $drc"; printf '%s\n' "$dry"; fail=1; fi
# symlink still present, markers still present after dry-run
if [ -L "$SBOX_BIN/bd" ]; then green "PASS: dry-run left the bd symlink in place"; else red "FAIL: dry-run removed the symlink"; fail=1; fi
if [ -f "$SBOX_REPO_A/.beads/FROZEN" ]; then green "PASS: dry-run left FROZEN markers"; else red "FAIL: dry-run removed a FROZEN marker"; fail=1; fi
# dry-run narrates the would-do actions
if printf '%s\n' "$dry" | grep -q "DRY-RUN would run: rm -f $SBOX_BIN/bd"; then green "PASS: dry-run narrated symlink removal"; else red "FAIL: dry-run did not narrate symlink removal"; fail=1; fi
if printf '%s\n' "$dry" | grep -q "DRY-RUN would run: git -C $SBOX_REPO_A config core.hooksPath $WANT_A"; then green "PASS: dry-run narrated hooksPath restore"; else red "FAIL: dry-run did not narrate hooksPath restore"; fail=1; fi

# ── (B) REAL rollback against the SANDBOX ──────────────────────────────
real="$(bash "$RB" 2>&1)"
rrc=$?
if [ "$rrc" -eq 0 ]; then green "PASS: real rollback exit 0"; else red "FAIL: rollback exit $rrc"; printf '%s\n' "$real"; fail=1; fi
# symlink removed
if [ ! -e "$SBOX_BIN/bd" ]; then green "PASS: bd symlink removed"; else red "FAIL: bd symlink still present"; fail=1; fi
# hooksPath restored on both sandbox repos
a_now="$(git -C "$SBOX_REPO_A" config --get core.hooksPath 2>/dev/null || echo '')"
b_now="$(git -C "$SBOX_REPO_B" config --get core.hooksPath 2>/dev/null || echo '')"
if [ "$a_now" = "$WANT_A" ]; then green "PASS: repo-a hooksPath restored to $WANT_A"; else red "FAIL: repo-a hooksPath=$a_now (want $WANT_A)"; fail=1; fi
if [ "$b_now" = "$WANT_B" ]; then green "PASS: repo-b hooksPath restored to $WANT_B"; else red "FAIL: repo-b hooksPath=$b_now (want $WANT_B)"; fail=1; fi
# markers removed
if [ ! -f "$SBOX_REPO_A/.beads/FROZEN" ] && [ ! -f "$SBOX_REPO_B/.beads/FROZEN" ]; then green "PASS: FROZEN markers removed"; else red "FAIL: a FROZEN marker survived"; fail=1; fi

# ── (C) idempotency — second run is a clean no-op ──────────────────────
real2="$(bash "$RB" 2>&1)"
rrc2=$?
if [ "$rrc2" -eq 0 ]; then green "PASS: second rollback is idempotent (exit 0)"; else red "FAIL: second rollback exit $rrc2"; fail=1; fi

# ── (D) safety — does NOT remove a non-bd-shim symlink ─────────────────
ln -snf /bin/echo "$SBOX_BIN/bd"   # a symlink that is NOT bd-shim
bash "$RB" >/dev/null 2>&1
if [ -L "$SBOX_BIN/bd" ]; then green "PASS: refused to remove a non-bd-shim symlink"; else red "FAIL: removed a symlink that wasn't ours"; fail=1; fi

# ── safety: real repo hooksPath untouched ──────────────────────────────
REAL_HOOKS_AFTER="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || echo '<unset>')"
if [ "$REAL_HOOKS_BEFORE" = "$REAL_HOOKS_AFTER" ]; then
    green "PASS: real repo hooksPath unchanged ($REAL_HOOKS_BEFORE)"
else
    red "FAIL: real repo hooksPath changed: $REAL_HOOKS_BEFORE → $REAL_HOOKS_AFTER"; fail=1
fi

rm -rf "$TMP"
[ "$fail" -eq 0 ] && green "flip-rollback.sh: ALL PASS" || red "flip-rollback.sh: FAILURES"
exit "$fail"
