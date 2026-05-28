#!/usr/bin/env bash
# tests/flip-dry-run.sh — W7d step 4 (w7-16).
# Asserts paperflow-flip-to-tasks --dry-run:
#   * prints all 6 phase headers,
#   * creates NO bd symlink,
#   * runs NO importer --apply (sentinel marker check),
#   * touches NO flipped-*.flag,
#   * writes NO flip-rollback.env,
#   * leaves the real core.hooksPath untouched.
# All side-effect-prone paths (LOCAL_BIN, PF_DIR, FLIP_REPOS) are redirected
# into a sandbox so the test never touches the real system.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FLIP="$REPO/bin/paperflow-flip-to-tasks"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

TMP="$(mktemp -d -t pf-flip-dry.XXXXXX)"
fail=0

# Sandbox layout.
SBOX_PF="$TMP/dot-paperflow"
SBOX_BIN="$TMP/local-bin"
SBOX_REPO_A="$TMP/repo-a"
SBOX_REPO_B="$TMP/repo-b"
mkdir -p "$SBOX_PF" "$SBOX_BIN" "$SBOX_REPO_A/.beads" "$SBOX_REPO_B/.beads"
git -C "$SBOX_REPO_A" init -q 2>/dev/null
git -C "$SBOX_REPO_B" init -q 2>/dev/null
# Give the sandbox repos a hooksPath so Phase 5 has something to (pretend to) unset.
git -C "$SBOX_REPO_A" config core.hooksPath "$SBOX_REPO_A/.beads/hooks"
git -C "$SBOX_REPO_B" config core.hooksPath "$SBOX_REPO_B/.beads/hooks"

# Sentinel importer shim — if invoked with --apply, touch a marker. Placed on a
# PATH ahead of the repo's real importer (flip resolves PATH first).
SHIM_DIR="$TMP/shim-bin"
mkdir -p "$SHIM_DIR"
IMP_MARKER="$TMP/importer-apply-called"
cat > "$SHIM_DIR/paperflow-import-bd" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--apply" ] && touch "$IMP_MARKER"; done
echo "STORE: shim"
echo "  imported: 0 / failed: 0"
exit 0
EOF
chmod +x "$SHIM_DIR/paperflow-import-bd"
# Doctor shim — gate always passes (so a dry-run on a machine w/o barkpark still
# exercises every phase). In dry-run the flip won't actually call it, but PATH
# resolution happens regardless.
cat > "$SHIM_DIR/paperflow-doctor" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"exit":0,"ensure_tasks":{}}'
exit 0
EOF
chmod +x "$SHIM_DIR/paperflow-doctor"

# Capture the REAL hooksPath of the actual paperflow repo before + after, to
# prove the test (and the dry-run) don't touch it.
REAL_HOOKS_BEFORE="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || echo '<unset>')"

out="$(
    PAPERFLOW_DIR="$SBOX_PF" \
    PAPERFLOW_LOCAL_BIN="$SBOX_BIN" \
    PAPERFLOW_FLIP_REPOS="$SBOX_REPO_A $SBOX_REPO_B" \
    PATH="$SHIM_DIR:$PATH" \
    bash "$FLIP" --dry-run 2>&1
)"
rc=$?

REAL_HOOKS_AFTER="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || echo '<unset>')"

# 1. exit 0
if [ "$rc" -eq 0 ]; then green "PASS: dry-run exit 0"; else red "FAIL: dry-run exit $rc"; printf '%s\n' "$out"; fail=1; fi

# 2. all 6 phase headers present
n_phases=0
for p in "Phase 0" "Phase 1" "Phase 2" "Phase 3" "Phase 4" "Phase 5" "Phase 6"; do
    printf '%s\n' "$out" | grep -q "$p" && n_phases=$((n_phases+1))
done
if [ "$n_phases" -eq 7 ]; then green "PASS: all phases 0-6 present (7 headers)"; else red "FAIL: only $n_phases/7 phase headers"; fail=1; fi

# 3. no bd symlink created
if [ -L "$SBOX_BIN/bd" ] || [ -e "$SBOX_BIN/bd" ]; then red "FAIL: bd symlink created in dry-run"; fail=1; else green "PASS: no bd symlink created"; fi

# 4. importer --apply never invoked
if [ -f "$IMP_MARKER" ]; then red "FAIL: importer --apply was invoked in dry-run"; fail=1; else green "PASS: importer --apply not invoked"; fi

# 5. no flipped-*.flag
if ls "$SBOX_PF"/flipped-*.flag >/dev/null 2>&1; then red "FAIL: a flipped-*.flag was touched"; fail=1; else green "PASS: no flipped flag touched"; fi

# 6. no rollback env written
if [ -f "$SBOX_PF/flip-rollback.env" ]; then red "FAIL: flip-rollback.env written in dry-run"; fail=1; else green "PASS: no flip-rollback.env written"; fi

# 7. sandbox repos' hooksPath unchanged (still set — dry-run didn't unset)
a_hooks="$(git -C "$SBOX_REPO_A" config --get core.hooksPath 2>/dev/null || echo '')"
if [ -n "$a_hooks" ]; then green "PASS: sandbox repo-a hooksPath untouched ($a_hooks)"; else red "FAIL: dry-run unset sandbox repo-a hooksPath"; fail=1; fi

# 8. real repo hooksPath identical before/after
if [ "$REAL_HOOKS_BEFORE" = "$REAL_HOOKS_AFTER" ]; then
    green "PASS: real repo hooksPath unchanged ($REAL_HOOKS_BEFORE)"
else
    red "FAIL: real repo hooksPath changed: $REAL_HOOKS_BEFORE → $REAL_HOOKS_AFTER"; fail=1
fi

# 9. dry-run narrates the would-run commands (proves the plan is printed)
if printf '%s\n' "$out" | grep -q 'DRY-RUN would run:'; then green "PASS: dry-run printed would-run command plan"; else red "FAIL: no would-run plan lines"; fail=1; fi

rm -rf "$TMP"
[ "$fail" -eq 0 ] && green "flip-dry-run.sh: ALL PASS" || red "flip-dry-run.sh: FAILURES"
exit "$fail"
