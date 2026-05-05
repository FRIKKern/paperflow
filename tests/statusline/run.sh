#!/usr/bin/env bash
# tests/statusline/run.sh — fixture runner for lib/statusline.sh
#
# For each tests/statusline/fixtures/*.in.json:
#   - Build a per-fixture HOME with a copy of lib/statusline-limits.json
#   - Substitute placeholders in the in.json (__REPO__, __GITREPO__, …)
#   - Source the matching .env (sets COLUMNS, optional PATH, STATUSLINE_DEBUG, …)
#   - Pipe the substituted JSON into bash lib/statusline.sh
#   - Diff stdout against .expected.txt (or grep regex against .expected.regex)
# Exit 0 iff every fixture passes.

set -u

# All existing fixtures predate ANSI colour/dim styling. NO_COLOR=1 keeps
# the renderer's output byte-identical to the pre-colour baseline so the
# whole fixture suite stays valid without churning every expected.txt.
# Color-aware fixtures (if/when added) should run in their own runner.
export NO_COLOR=1

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIXDIR="$REPO/tests/statusline/fixtures"
SCRIPT="$REPO/lib/statusline.sh"
LIMITS_SRC="$REPO/lib/statusline-limits.json"
MOCK_BD_DIR="$REPO/tests/statusline/mock-bd-bin"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

if [ ! -x "$SCRIPT" ]; then
    chmod +x "$SCRIPT" 2>/dev/null || true
fi

# ─── One-time scaffolding shared by every fixture ──────────────────────
SCAFFOLD=$(mktemp -d) || { red "FAIL: cannot mktemp"; exit 2; }
trap 'rm -rf "$SCAFFOLD" 2>/dev/null; chmod 644 "$UNREADABLE" 2>/dev/null || true' EXIT

# Git repo named "paperflow" on branch "main".
GITREPO="$SCAFFOLD/paperflow"
mkdir -p "$GITREPO"
(
    cd "$GITREPO"
    git init -q -b main . 2>/dev/null || { git init -q . && git checkout -q -b main 2>/dev/null; }
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init >/dev/null 2>&1 || true
) || true

# Non-git dir named "Downloads".
NOGITDIR="$SCAFFOLD/Downloads"
mkdir -p "$NOGITDIR"

# ANSI-branch git shim.
ANSIBIN="$SCAFFOLD/ansibin"
mkdir -p "$ANSIBIN"
cat > "$ANSIBIN/git" <<'SHIM'
#!/usr/bin/env bash
# Minimal git shim — only handles the call statusline.sh makes.
# Prints branch name with embedded ANSI escape (0x1b[31mEVIL).
case "$*" in
    *"rev-parse --abbrev-ref HEAD"*)
        printf 'main\033[31mEVIL\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
chmod +x "$ANSIBIN/git"

# Unreadable transcript path.
UNREADABLE="$SCAFFOLD/unreadable.jsonl"
echo '{"unread":true}' > "$UNREADABLE"
chmod 000 "$UNREADABLE"

# A bin dir containing every utility except jq, for the jq-missing fixture.
NOJQ="$SCAFFOLD/nojq-bin"
mkdir -p "$NOJQ"
for t in bash cat mktemp tr sed head tail stat date find shasum git printf awk basename touch mv rm mkdir cp pwd dirname env id chmod ls cut sleep sort wc; do
    src=$(command -v "$t" 2>/dev/null || true)
    if [ -n "$src" ] && [ "$(basename "$src")" != "jq" ]; then
        ln -s "$src" "$NOJQ/$t" 2>/dev/null || true
    fi
done

# A bin dir containing every utility EXCEPT bd, for the bd-missing fixture.
# jq is included so the v8 line still renders; bd is omitted so the
# statusline's command -v bd check fails and the goal/phase/task code path
# is silent-skipped.
NOBD="$SCAFFOLD/nobd-bin"
mkdir -p "$NOBD"
for t in bash cat mktemp tr sed head tail stat date find shasum git printf awk basename touch mv rm mkdir cp pwd dirname env id chmod ls cut sleep sort wc jq; do
    src=$(command -v "$t" 2>/dev/null || true)
    if [ -n "$src" ] && [ "$(basename "$src")" != "bd" ]; then
        ln -s "$src" "$NOBD/$t" 2>/dev/null || true
    fi
done

# ─── Iterate fixtures ──────────────────────────────────────────────────
FAIL=0
PASS=0
TOTAL=0

for in_json in "$FIXDIR"/*.in.json; do
    name=$(basename "$in_json" .in.json)
    TOTAL=$((TOTAL + 1))

    expected_txt="$FIXDIR/$name.expected.txt"
    expected_re="$FIXDIR/$name.expected.regex"
    envfile="$FIXDIR/$name.env"

    if [ ! -f "$expected_txt" ] && [ ! -f "$expected_re" ]; then
        red "FAIL: $name — no expected file"
        FAIL=1
        continue
    fi

    # Per-fixture HOME with limits.json.
    tmphome=$(mktemp -d) || { red "FAIL: $name — mktemp"; FAIL=1; continue; }
    mkdir -p "$tmphome/.paperflow"
    cp "$LIMITS_SRC" "$tmphome/.paperflow/statusline-limits.json"

    # Per-fixture GOALREPO — a fresh git repo named "paperflow" on branch
    # "main", into which .paperflow/active-goal + .paperflow/active-phase can
    # be written by the optional <fixture>.setup. Distinct from the shared
    # GITREPO so pointer files don't leak between fixtures.
    GOALREPO="$tmphome/paperflow-goal"
    mkdir -p "$GOALREPO"
    (
        cd "$GOALREPO"
        git init -q -b main . 2>/dev/null || { git init -q . && git checkout -q -b main 2>/dev/null; }
        git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init >/dev/null 2>&1 || true
    ) || true
    mkdir -p "$GOALREPO/.paperflow"

    # Optional per-fixture setup script. Receives GOALREPO + tmphome in env.
    setup_script="$FIXDIR/$name.setup"
    if [ -f "$setup_script" ]; then
        # shellcheck disable=SC1090
        ( export GOALREPO="$GOALREPO"; export PFHOME="$tmphome"; bash "$setup_script" ) || true
    fi

    # Substitute placeholders.
    substituted=$(mktemp) || { red "FAIL: $name — mktemp substituted"; rm -rf "$tmphome"; FAIL=1; continue; }
    sed -e "s|__REPO__|$REPO|g" \
        -e "s|__GITREPO__|$GITREPO|g" \
        -e "s|__GOALREPO__|$GOALREPO|g" \
        -e "s|__NOGITDIR__|$NOGITDIR|g" \
        -e "s|__ANSIBIN__|$ANSIBIN|g" \
        -e "s|__UNREADABLE__|$UNREADABLE|g" \
        -e "s|__NOJQ__|$NOJQ|g" \
        -e "s|__NOBD__|$NOBD|g" \
        -e "s|__MOCKBD__|$MOCK_BD_DIR|g" \
        "$in_json" > "$substituted"

    # Substitute placeholders in env file too (so __ANSIBIN__ becomes a real path).
    envfile_resolved=""
    if [ -f "$envfile" ]; then
        envfile_resolved=$(mktemp) || envfile_resolved=""
        if [ -n "$envfile_resolved" ]; then
            sed -e "s|__REPO__|$REPO|g" \
                -e "s|__GITREPO__|$GITREPO|g" \
                -e "s|__GOALREPO__|$GOALREPO|g" \
                -e "s|__NOGITDIR__|$NOGITDIR|g" \
                -e "s|__ANSIBIN__|$ANSIBIN|g" \
                -e "s|__UNREADABLE__|$UNREADABLE|g" \
                -e "s|__NOJQ__|$NOJQ|g" \
                -e "s|__NOBD__|$NOBD|g" \
                -e "s|__MOCKBD__|$MOCK_BD_DIR|g" \
                "$envfile" > "$envfile_resolved"
        fi
    fi

    out=$(mktemp) || { red "FAIL: $name — mktemp out"; rm -rf "$tmphome"; rm -f "$substituted" "$envfile_resolved"; FAIL=1; continue; }

    # Run in a subshell so env doesn't leak between fixtures.
    # Use `set -a` so any var assignments in the env file are exported automatically.
    (
        export HOME="$tmphome"
        if [ -n "$envfile_resolved" ] && [ -f "$envfile_resolved" ]; then
            set -a
            # shellcheck disable=SC1090
            . "$envfile_resolved"
            set +a
        fi
        bash "$SCRIPT" < "$substituted" > "$out" 2>/dev/null
    )

    rc=$?

    if [ -f "$expected_txt" ]; then
        if diff -u "$expected_txt" "$out" >/dev/null 2>&1; then
            green "  ok: $name"
            PASS=$((PASS + 1))
        else
            red "FAIL: $name"
            diff -u "$expected_txt" "$out" || true
            FAIL=1
        fi
    elif [ -f "$expected_re" ]; then
        re=$(cat "$expected_re")
        if grep -Eq "$re" "$out"; then
            green "  ok: $name"
            PASS=$((PASS + 1))
        else
            red "FAIL: $name — output did not match regex"
            yellow "  regex:    $re"
            yellow "  got:      $(cat "$out")"
            FAIL=1
        fi
    fi

    if [ "$rc" -ne 0 ]; then
        red "FAIL: $name — script exited $rc"
        FAIL=1
    fi

    rm -rf "$tmphome" 2>/dev/null
    rm -f "$substituted" "$out" 2>/dev/null
done

echo
if [ "$FAIL" -eq 0 ]; then
    green "All $PASS/$TOTAL fixtures passed"
    exit 0
else
    red "Some fixtures failed ($PASS/$TOTAL passed)"
    exit 1
fi
