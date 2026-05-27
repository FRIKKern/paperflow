#!/usr/bin/env bash
# tests/rail-proxy.sh — W7c step 3 (w7-11 / paperflow-158) gate for the
# paperflow-daemon rail proxy.
#
# Three states, each must pass independently:
#
#   1. env UNSET → /paperflow/goal-path returns 410 (daily-driver unchanged).
#   2. env SET + barkpark UP on :4001 with one seeded event → proxy returns
#      200 with the barkpark JSON shape.
#   3. env SET + barkpark UNREACHABLE on :9999 → graceful fallback to 410,
#      no hang past the 3s RAIL_PROXY_TIMEOUT_MS.
#
# The harness spawns paperflow-daemon on a non-default PORT to avoid
# colliding with the host's daemon (which may already be running on 8767).
# State 2 SKIPs cleanly if barkpark isn't reachable on :4001 — matches the
# convention of tests/doc-meta-mirror-up.sh.
#
# Exit 0 on pass-or-skip, 1 on hard fail.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$REPO/bin/paperflow-daemon"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Pick an unused-ish port for the daemon under test — high range, randomised
# from PID so reruns don't collide.
DAEMON_PORT="$((30000 + RANDOM % 30000))"
DAEMON_URL="http://127.0.0.1:${DAEMON_PORT}"
BARKPARK_UP_URL="${PAPERFLOW_BARKPARK_URL:-http://localhost:4001}"
BARKPARK_DOWN_URL="http://127.0.0.1:9999"

# Guardrail: never run state-2 against :4000 (production daily driver).
case "$BARKPARK_UP_URL" in
    *:4000*)
        red "FAIL: refusing to point rail-proxy test at :4000 (production barkpark)"
        exit 1
        ;;
esac

# Spawn paperflow-daemon under test on the chosen port. Background it; tear
# down on EXIT.
DAEMON_LOG="$(mktemp -t rail-proxy-daemon.XXXXXX)"
PORT="$DAEMON_PORT" HOST=127.0.0.1 \
    node "$DAEMON" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

cleanup() {
    if [ -n "${DAEMON_PID:-}" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -f "$DAEMON_LOG"
}
trap cleanup EXIT INT TERM

# Wait for the daemon to start listening (cap 5s).
ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sS -m 1 -o /dev/null "$DAEMON_URL/health" 2>/dev/null; then
        ready=1; break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    red "FAIL: paperflow-daemon did not start on $DAEMON_URL within 5s"
    cat "$DAEMON_LOG"
    exit 1
fi

# ─── State 1: env unset → 410 ────────────────────────────────────────────
unset PAPERFLOW_MIRROR_GOALS PAPERFLOW_BARKPARK_URL

# Important nuance: the daemon reads env at request time, but it inherits
# THIS shell's env via the fork at spawn-time. unset above affects this
# shell only — the daemon child already has those vars (unset) inherited.
# Validate by GETting the rail path.
code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$DAEMON_URL/paperflow/goal-path?goal=foo")"
if [ "$code" != "410" ]; then
    red "FAIL state-1 (env unset): expected 410, got $code"
    exit 1
fi
green "PASS state-1 (env unset → 410)"

# Restart the daemon with env SET so it sees them at request time.
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true

PAPERFLOW_MIRROR_GOALS=1 PAPERFLOW_BARKPARK_URL="$BARKPARK_UP_URL" \
    PORT="$DAEMON_PORT" HOST=127.0.0.1 \
    node "$DAEMON" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sS -m 1 -o /dev/null "$DAEMON_URL/health" 2>/dev/null; then
        ready=1; break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    red "FAIL: paperflow-daemon (state-2 restart) did not start on $DAEMON_URL within 5s"
    cat "$DAEMON_LOG"
    exit 1
fi

# ─── State 2: env set, barkpark UP → 200 from barkpark ───────────────────
# Probe barkpark on :4001. If unreachable, SKIP this state (test environments
# rarely have barkpark running by default).
bp_code="$(curl -s -m 1 -o /dev/null -w '%{http_code}' "$BARKPARK_UP_URL/v1/tasks" \
    -H "Authorization: Bearer barkpark-dev-token" 2>/dev/null || echo 000)"
case "$bp_code" in
    2*|4*)
        # Barkpark answering. Probe through the daemon proxy with a known-
        # absent goal id — barkpark returns 200 {events:[]} (per rail
        # controller's "missing goal → empty events" contract).
        body="$(curl -sS -m 5 "$DAEMON_URL/paperflow/goal-path?goal=does-not-exist-$$")"
        code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$DAEMON_URL/paperflow/goal-path?goal=does-not-exist-$$")"
        if [ "$code" != "200" ]; then
            red "FAIL state-2 (barkpark up): expected 200 from proxy, got $code"
            printf '  body: %s\n' "$body" | head -c 400
            exit 1
        fi
        if ! printf '%s' "$body" | grep -q '"events"'; then
            red "FAIL state-2: 200 received but body lacks 'events' key"
            printf '  body: %s\n' "$body" | head -c 400
            exit 1
        fi
        green "PASS state-2 (env set + barkpark up → 200 proxied)"
        ;;
    *)
        yellow "SKIP state-2: barkpark not reachable at $BARKPARK_UP_URL (http=$bp_code)"
        ;;
esac

# ─── State 3: env set, barkpark DOWN → 410 graceful fallback, <3s ────────
# Same daemon process, but flip env URL for the next restart.
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true

PAPERFLOW_MIRROR_GOALS=1 PAPERFLOW_BARKPARK_URL="$BARKPARK_DOWN_URL" \
    PORT="$DAEMON_PORT" HOST=127.0.0.1 \
    node "$DAEMON" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sS -m 1 -o /dev/null "$DAEMON_URL/health" 2>/dev/null; then
        ready=1; break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    red "FAIL: paperflow-daemon (state-3 restart) did not start on $DAEMON_URL within 5s"
    cat "$DAEMON_LOG"
    exit 1
fi

# Measure latency — ECONNREFUSED on :9999 should be near-instant on Linux
# and macOS; we just cap at 3.5s to verify the proxy timeout fired and the
# fallback ran (not a real hang).
t_start="$(date +%s)"
code="$(curl -s -m 4 -o /dev/null -w '%{http_code}' "$DAEMON_URL/paperflow/goal-path?goal=foo")"
t_end="$(date +%s)"
elapsed=$(( t_end - t_start ))

if [ "$code" != "410" ]; then
    red "FAIL state-3 (barkpark down): expected 410 graceful fallback, got $code"
    exit 1
fi
if [ "$elapsed" -gt 3 ]; then
    red "FAIL state-3: fallback latency ${elapsed}s exceeds 3s budget (timeout misfire?)"
    exit 1
fi
green "PASS state-3 (env set + barkpark down → 410 fallback in ${elapsed}s)"

green "─── rail-proxy: ALL PASS ───"
exit 0
