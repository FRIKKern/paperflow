#!/usr/bin/env bash
# tests/dock-smoke.sh — exercise paperflow-dock-{daemon,feed} in two states.
#
# For each (feed, state) pair we invoke `paperflow-dock-feed <name>` against a
# test-isolated daemon (its own socket, its own PID file, its own ~/.paperflow
# tree synthesised in $TMPDIR) and assert that every substring listed in the
# matching fixture appears in the output. Substring assertions tolerate
# timestamps and bd ids that drift between runs without churning fixtures.
#
# 4 feeds × 2 states = 8 fixtures. Exit 0 iff every assertion passes.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$REPO/bin/paperflow-dock-daemon"
FEED="$REPO/bin/paperflow-dock-feed"
FIXDIR="$REPO/tests/dock/fixtures"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -x "$DAEMON" ] || { red "FAIL: missing daemon at $DAEMON"; exit 2; }
[ -x "$FEED" ]   || { red "FAIL: missing feed client at $FEED"; exit 2; }

# Per-test sandbox.
SANDBOX="$(mktemp -d)" || { red "FAIL: cannot mktemp"; exit 2; }
SOCK="$SANDBOX/dock.sock"
PID_FILE="$SANDBOX/dock-daemon.pid"
PF_DIR="$SANDBOX/.paperflow"
mkdir -p "$PF_DIR"

cleanup() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        sleep 0.2
    fi
    rm -rf "$SANDBOX" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Spawn the daemon with a sandboxed HOME so it writes pid/sock/log into us.
PAPERFLOW_DOCK_SOCK="$SOCK" \
HOME="$SANDBOX" \
"$DAEMON" >"$SANDBOX/daemon.log" 2>&1 &
DAEMON_PID=$!
echo "$DAEMON_PID" > "$PID_FILE"

# Wait for socket.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$SOCK" ] && break
    sleep 0.3
done
if [ ! -S "$SOCK" ]; then
    red "FAIL: daemon did not create socket at $SOCK"
    cat "$SANDBOX/daemon.log" >&2 || true
    exit 1
fi

PASS=0; FAIL=0; FAILED_NAMES=""

assert_substrings() {
    local label="$1" fixture="$2" out="$3"
    if [ ! -f "$fixture" ]; then
        red "FAIL [$label]: missing fixture $fixture"
        FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $label"; return
    fi
    local missing=""
    while IFS= read -r line; do
        # Skip blank / comment lines.
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        case "$line" in
            "SUBSTRING:"*)
                local needle="${line#SUBSTRING:}"
                # Strip exactly one leading space if present (the convention).
                needle="${needle# }"
                if ! printf '%s' "$out" | /usr/bin/grep -qF -- "$needle"; then
                    missing="$missing\n    needle missing: $needle"
                fi
                ;;
        esac
    done < "$fixture"
    if [ -z "$missing" ]; then
        green "PASS [$label]"
        PASS=$((PASS + 1))
    else
        red "FAIL [$label]:"
        printf -- "$missing\n" >&2
        echo "  --- actual output ---" >&2
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $label"
    fi
}

run_feed() {
    PAPERFLOW_DOCK_SOCK="$SOCK" "$FEED" "$1" 2>&1
}

# ───── State 1: no active goal ──────────────────────────────────────
# active-goal pointer is absent. Daemon serves "No active goal." for all.
rm -f "$PF_DIR/active-goal" "$PF_DIR/active-phase" 2>/dev/null || true
sleep 6.5  # full poll cycle: ~5 sequential bd calls × ~1 s each

for name in active-context bd-ready goal-path auto-open-log; do
    out="$(run_feed "$name")"
    assert_substrings "$name/no-goal" "$FIXDIR/${name}-no-goal.txt" "$out"
done

# ───── State 2: active goal — paperflow-r0o (this repo's live state) ─
# We use the live ~/.paperflow store (read-only from the test's view) by
# pointing HOME there for the next daemon. To avoid re-spawning the daemon,
# we just write into the sandbox's pointer files — except the daemon is
# *already* spawned with HOME=$SANDBOX so it reads $PF_DIR/active-goal,
# not the user's. We synthesise an active-goal pointer that points at
# whatever real Beads goal we can find; if `bd` returns nothing we
# fall through with a known-bad id and assert the per-feed fallback strings.
ACTIVE_GOAL_ID="$(bd list --label kind:goal --json 2>/dev/null \
    | /usr/bin/grep -oE '"id":[[:space:]]*"[a-z0-9-]+"' \
    | /usr/bin/head -n1 \
    | /usr/bin/sed -E 's/^"id":[[:space:]]*"([^"]+)"$/\1/' || true)"
if [ -z "$ACTIVE_GOAL_ID" ]; then
    yellow "WARN: no kind:goal in Beads — using sentinel id 'paperflow-test'"
    ACTIVE_GOAL_ID="paperflow-test"
fi
yellow "  using ACTIVE_GOAL_ID=$ACTIVE_GOAL_ID"
echo "$ACTIVE_GOAL_ID" > "$PF_DIR/active-goal"
# Each pollOnce makes ~5 sequential bd calls × ~1 s; wait until the
# active-context feed actually reflects the pointer, with a hard cap.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if printf 'active-context\n' | /usr/bin/nc -U -w 2 "$SOCK" 2>/dev/null | /usr/bin/grep -q '^Goal:'; then
        break
    fi
done

for name in active-context bd-ready goal-path auto-open-log; do
    out="$(run_feed "$name")"
    assert_substrings "$name/active" "$FIXDIR/${name}-active.txt" "$out"
done

# ───── Summary ──────────────────────────────────────────────────────
echo
echo "─── dock-smoke summary ───"
echo "  pass: $PASS"
echo "  fail: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    yellow "  failures:$FAILED_NAMES"
    exit 1
fi
green "✓ all 8 fixture checks passed"
exit 0
