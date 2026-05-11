#!/usr/bin/env bash
# Emits JSON describing the current Claude Code session's per-instance
# bridge target. Performs a SYNCHRONOUS registration handshake against
# the bridge daemon at doc-write time (spec G1 —
# /Users/frikk.jarl/docs/paperflow/specs/2026-05-11-bridge-binding-contract.html).
#
# Output shape (success):
#   {
#     "bridge_url": "http://localhost:<dynamic-port>",
#     "doc_nonce":  "<uuid>",
#     "session_id": "<id>",
#     "cmux_workspace": "<id-or-null>"
#   }
#
# Output shape (failure): structured JSON to stdout, non-zero exit:
#   exit 2 → {"ok":false,"error":"no-daemon",...}
#   exit 3 → {"ok":false,"error":"register-failed",...}
#
# Usage:
#   get-terminal-target.sh [<doc_path>]
#
# Env knobs:
#   PAPERFLOW_TARGET_LEGACY=1   also emit legacy fields (term_program,
#                               cmux_cli, cmux_workspace, cmux_surface, tty,
#                               term_session_id, tmux_pane, pid) — kept for
#                               docs predating the per-instance migration.
#   PAPERFLOW_SKIP_REGISTER=1   skip the POST /docs/register handshake (used
#                               by smoke-tests and the doctor; not a normal
#                               code path).

set -e

DOC_PATH="${1:-}"

# ── 1. resolve session_id ───────────────────────────────────────────
# Source of truth (in order): CLAUDE_SESSION_ID env var; else
# CMUX_WORKSPACE_ID+CMUX_SURFACE_REF combo; else process-tree walk for
# a parent `claude` process PID. First source that resolves wins.
resolve_session_id() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    printf '%s\n' "$CLAUDE_SESSION_ID"
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "${CMUX_SURFACE_REF:-}" ]; then
    # Combine workspace + surface into a stable per-pane id. Replace any
    # path-unsafe chars so the result is fine as a filename.
    local combined="${CMUX_WORKSPACE_ID}-${CMUX_SURFACE_REF}"
    printf '%s\n' "${combined//[\/.]/_}"
    return 0
  fi
  # Walk up process tree looking for a `claude` ancestor.
  local pid="$$"
  local tries=0
  while [ "$pid" -gt 1 ] && [ "$tries" -lt 20 ]; do
    local comm ppid
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ "$(basename "$comm" 2>/dev/null)" = "claude" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$ppid" ] || break
    pid="$ppid"
    tries=$((tries + 1))
  done
  return 1
}

SESSION_ID="$(resolve_session_id || true)"

emit_error() {
  # emit_error <exit-code> <error-code> <message> [<extra-json>]
  local exit_code="$1"
  local err="$2"
  local msg="$3"
  local extra="${4:-}"
  if [ -z "$extra" ]; then
    extra='{}'
  fi
  /usr/bin/env jq -n \
    --arg err "$err" \
    --arg sid "${SESSION_ID:-}" \
    --arg msg "$msg" \
    --argjson extra "$extra" \
    '{ok:false, error:$err, session_id:(if $sid=="" then null else $sid end), message:$msg} + $extra'
  exit "$exit_code"
}

if [ -z "$SESSION_ID" ]; then
  emit_error 2 "no-daemon" "Could not resolve a session_id (no \$CLAUDE_SESSION_ID, no cmux env, no claude ancestor process). Run install.sh or start a fresh Claude Code session to spawn a paperflow bridge daemon."
fi

# ── 2. read port from instance state file ───────────────────────────
STATE_FILE="${HOME}/.paperflow/instances/${SESSION_ID}.jsonl"

if [ ! -f "$STATE_FILE" ]; then
  emit_error 2 "no-daemon" "No instance state file at ~/.paperflow/instances/${SESSION_ID}.jsonl — bridge daemon for this session has not been spawned. Run install.sh or start a fresh Claude Code session to spawn a paperflow bridge daemon."
fi

# First line is the {type:"session", port, ...} record written atomically
# at daemon startup. Heartbeat/registration lines follow.
FIRST_LINE="$(head -n 1 "$STATE_FILE" 2>/dev/null || true)"

if [ -z "$FIRST_LINE" ]; then
  emit_error 2 "no-daemon" "Instance state file is empty for session ${SESSION_ID}. Run install.sh or start a fresh Claude Code session."
fi

# Validate JSON + extract port. jq returns null/empty on missing fields;
# we want a hard failure in that case.
PORT="$(printf '%s' "$FIRST_LINE" | /usr/bin/env jq -r 'select(.type=="session") | .port // empty' 2>/dev/null || true)"

if [ -z "$PORT" ] || ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  emit_error 2 "no-daemon" "Cannot parse port from first line of ${STATE_FILE}. Run install.sh or start a fresh Claude Code session."
fi

# cmux_workspace is preserved for the discovery flow (live-server's
# /paperflow/discover filters by workspace for sibling-session rebind UX).
CMUX_WORKSPACE="$(printf '%s' "$FIRST_LINE" | /usr/bin/env jq -r 'select(.type=="session") | .cmux_workspace // empty' 2>/dev/null || true)"

BRIDGE_URL="http://localhost:${PORT}"

# ── 3. generate doc_nonce ───────────────────────────────────────────
gen_nonce() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  # Fallback — best-effort 32-char hex. macOS lacks sha256sum, use
  # shasum -a 256 instead; both `date +%s%N` and python random as last resort.
  local seed=""
  if date +%s%N | grep -qE '^[0-9]+$'; then
    seed="$(date +%s%N)-$$-$RANDOM"
  else
    # macOS `date` doesn't support %N — use perl as a substitute.
    seed="$(perl -MTime::HiRes=time -e 'printf "%d-%d", time*1e6, $$' 2>/dev/null || echo "$(date +%s)-$$-$RANDOM")"
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$seed" | shasum -a 256 | cut -c1-32
  else
    printf '%s' "$seed" | /usr/bin/env openssl dgst -sha256 | tr -d ' ' | tail -c 33 | head -c 32
  fi
}

DOC_NONCE="$(gen_nonce)"

if [ -z "$DOC_NONCE" ]; then
  emit_error 3 "register-failed" "Could not generate doc_nonce (no uuidgen, shasum, or openssl available)."
fi

# ── 4. POST /docs/register synchronously ────────────────────────────
if [ "${PAPERFLOW_SKIP_REGISTER:-}" != "1" ]; then
  REGISTER_BODY="$(/usr/bin/env jq -n \
    --arg dp "${DOC_PATH:-}" \
    --arg dn "$DOC_NONCE" \
    '{doc_path:$dp, doc_nonce:$dn}')"

  REGISTER_RESPONSE="$(curl -sS --max-time 3 --fail \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "$REGISTER_BODY" \
    "${BRIDGE_URL}/docs/register" 2>&1)" || {
    emit_error 3 "register-failed" "POST ${BRIDGE_URL}/docs/register failed: ${REGISTER_RESPONSE}" \
      "$(/usr/bin/env jq -n --arg port "$PORT" '{port:($port|tonumber)}')"
  }

  # Validate the response — daemon returns {ok:true} on success.
  REGISTER_OK="$(printf '%s' "$REGISTER_RESPONSE" | /usr/bin/env jq -r '.ok // false' 2>/dev/null || echo "false")"
  if [ "$REGISTER_OK" != "true" ]; then
    emit_error 3 "register-failed" "daemon responded but ok!=true: ${REGISTER_RESPONSE}" \
      "$(/usr/bin/env jq -n --arg port "$PORT" '{port:($port|tonumber)}')"
  fi
fi

# ── 5. emit target JSON ─────────────────────────────────────────────
if [ "${PAPERFLOW_TARGET_LEGACY:-}" = "1" ]; then
  # Legacy shim — best-effort fill from env. New docs do NOT use these
  # fields; they exist so docs predating the migration keep parsing.
  CLAUDE_PID=""
  CLAUDE_TTY=""
  if [ -z "${CMUX_SURFACE_REF:-}" ]; then
    # tty-based fallback path (Apple_Terminal / iTerm.app)
    pid="$$"
    tries=0
    while [ "$pid" -gt 1 ] && [ "$tries" -lt 20 ]; do
      comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
      tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
      if [ "$comm" = "claude" ] && [ -n "$tty" ] && [ "$tty" != "??" ]; then
        CLAUDE_PID="$pid"
        CLAUDE_TTY="/dev/$tty"
        break
      fi
      ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
      [ -n "$ppid" ] || break
      pid="$ppid"
      tries=$((tries + 1))
    done
  fi

  /usr/bin/env jq -n \
    --arg url   "$BRIDGE_URL" \
    --arg dn    "$DOC_NONCE" \
    --arg sid   "$SESSION_ID" \
    --arg ws    "$CMUX_WORKSPACE" \
    --arg tp    "${TERM_PROGRAM:-${CMUX_SURFACE_REF:+cmux}}" \
    --arg cli   "${CMUX_BUNDLED_CLI_PATH:-}" \
    --arg sf    "${CMUX_SURFACE_REF:-}" \
    --arg tty   "$CLAUDE_TTY" \
    --arg tsid  "${TERM_SESSION_ID:-}" \
    --arg tmux  "${TMUX:-}" \
    --arg pid   "$CLAUDE_PID" \
    '{
      bridge_url: $url,
      doc_nonce:  $dn,
      session_id: $sid,
      cmux_workspace: (if $ws == "" then null else $ws end),
      term_program:   (if $tp == "" then "unknown" else $tp end),
      cmux_cli:       (if $cli == "" then null else $cli end),
      cmux_surface:   (if $sf == "" then null else $sf end),
      tty:            (if $tty == "" then null else $tty end),
      term_session_id: $tsid,
      tmux_pane:      $tmux,
      pid:            ($pid | tonumber? // null)
    }'
else
  /usr/bin/env jq -n \
    --arg url "$BRIDGE_URL" \
    --arg dn  "$DOC_NONCE" \
    --arg sid "$SESSION_ID" \
    --arg ws  "$CMUX_WORKSPACE" \
    '{
      bridge_url: $url,
      doc_nonce:  $dn,
      session_id: $sid,
      cmux_workspace: (if $ws == "" then null else $ws end)
    }'
fi
