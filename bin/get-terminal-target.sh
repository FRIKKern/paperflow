#!/usr/bin/env bash
# Emits JSON describing the current Claude Code session's paperflow
# daemon target. Performs a SYNCHRONOUS registration handshake against
# the consolidated daemon (single :8767 process — replaces the per-
# instance claude-bridge.js spawn). Spec G1, B4 rewrite (paperflow-8ea).
#
# Output shape (success):
#   {
#     "daemon_url": "http://localhost:8767",
#     "bridge_url": "http://localhost:8767",   # back-compat alias
#     "doc_nonce":  "<uuid>",
#     "session_id": "<id>",
#     "cmux_workspace": "<id-or-null>"
#   }
#
# Output shape (failure): structured JSON to stdout, non-zero exit:
#   exit 2 → {"ok":false,"error":"no-session-id" | "no-daemon",...}
#   exit 3 → {"ok":false,"error":"register-failed",...}
#
# Usage:
#   get-terminal-target.sh [<doc_path>]
#
# Env knobs:
#   PAPERFLOW_DAEMON_URL        override the daemon URL (default
#                               http://localhost:8767). Used by smoke
#                               tests; in production the port is fixed.
#   PAPERFLOW_TARGET_LEGACY=1   also emit legacy fields (term_program,
#                               cmux_cli, cmux_workspace, cmux_surface, tty,
#                               term_session_id, tmux_pane, pid) — kept for
#                               docs predating the per-instance migration.
#   PAPERFLOW_SKIP_REGISTER=1   skip the POST /docs/register handshake. Used
#                               by the doctor to inspect a live daemon without
#                               side-effects on the nonce registry.

set -e

DOC_PATH="${1:-}"

# ── 1. resolve session_id ───────────────────────────────────────────
# Source of truth (in order):
#   1. $CLAUDE_SESSION_ID env var (most explicit, highest priority).
#   2. Sidecar file ~/.paperflow/instances/<sid>.session — written by
#      the paperflow-session-register SessionStart hook (B3). Single-
#      line file containing just the session_id. Pick the most-
#      recently-modified one (unambiguous on the common case of one
#      Claude session per machine).
#   3. Daemon GET /sessions/discover — when multiple sidecars exist,
#      filter by $CMUX_WORKSPACE_ID (if set) and prefer the session
#      whose record matches our environment. Last write wins on tie.
#
# NO process-tree walk fallback. The proctree walk was removed in B4
# (paperflow-8ea) because from a deep subagent context the parent-pid
# chain leads to the subagent's launcher — not the Claude UI process —
# so the resolver matched random PIDs and routed doc-button clicks
# into the void. If steps 1-3 all fail we exit 2 with "no-session-id".
resolve_session_id() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    printf '%s\n' "$CLAUDE_SESSION_ID"
    return 0
  fi

  local instances_dir="${HOME}/.paperflow/instances"
  if [ ! -d "$instances_dir" ]; then
    return 1
  fi

  # Collect *.session files (bash 3.2 — no mapfile, no globstar).
  # `ls -t` orders newest-first by mtime; we read line-by-line so
  # filenames with spaces still work even though our sids are
  # uuid-shaped in practice.
  local newest_file=""
  local count=0
  local f
  # shellcheck disable=SC2012
  for f in $(ls -t "$instances_dir"/*.session 2>/dev/null); do
    [ -e "$f" ] || continue
    count=$((count + 1))
    if [ -z "$newest_file" ]; then
      newest_file="$f"
    fi
  done

  if [ "$count" -eq 0 ]; then
    return 1
  fi

  # If there's exactly one sidecar, trust it. With one active Claude
  # session per machine (the common case) this is unambiguous.
  if [ "$count" -eq 1 ]; then
    local sid_one
    sid_one="$(head -n 1 "$newest_file" 2>/dev/null | tr -d ' \n\r' || true)"
    if [ -n "$sid_one" ]; then
      printf '%s\n' "$sid_one"
      return 0
    fi
    return 1
  fi

  # Multiple sidecars — disambiguate via the daemon's discovery
  # endpoint. Filter by $CMUX_WORKSPACE_ID when set so cmux surfaces
  # route to their own session. Fall back to newest sidecar otherwise.
  local daemon_url="${PAPERFLOW_DAEMON_URL:-http://localhost:8767}"
  local ws_arg=""
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    ws_arg="?workspace=${CMUX_WORKSPACE_ID}"
  fi
  local discover_sid
  discover_sid="$(curl -sS --max-time 2 \
    "${daemon_url}/sessions/discover${ws_arg}" 2>/dev/null \
    | /usr/bin/env jq -r '.sessions[0].session_id // empty' 2>/dev/null || true)"
  if [ -n "$discover_sid" ]; then
    printf '%s\n' "$discover_sid"
    return 0
  fi

  # Fallback to newest sidecar's content.
  local sid_newest
  sid_newest="$(head -n 1 "$newest_file" 2>/dev/null | tr -d ' \n\r' || true)"
  if [ -n "$sid_newest" ]; then
    printf '%s\n' "$sid_newest"
    return 0
  fi
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
  emit_error 2 "no-session-id" "Could not resolve session_id. Make sure paperflow-session-register fired on SessionStart. The fallback proctree walk was removed in B4 (paperflow-8ea) because it returned wrong PIDs from subagent contexts."
fi

# ── 2. consolidated daemon URL (fixed port) ─────────────────────────
# The per-instance bridge daemon is gone (B1/B2 of paperflow-s2e). A
# single paperflow-daemon process listens on :8767. The dynamic port
# read from ~/.paperflow/instances/<sid>.jsonl is no longer needed —
# that file format also went away with the per-instance migration.
# PAPERFLOW_DAEMON_URL lets the smoke test point at an ad-hoc port.
DAEMON_URL="${PAPERFLOW_DAEMON_URL:-http://localhost:8767}"
BRIDGE_URL="$DAEMON_URL"

# cmux_workspace is preserved for the discovery flow (the daemon's
# /sessions/discover filters by workspace for sibling-session rebind UX).
# Source it from the live env — the sidecar file no longer carries it.
CMUX_WORKSPACE="${CMUX_WORKSPACE_ID:-${CMUX_WORKSPACE:-}}"

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
# Default behavior: register. If no doc_path was supplied AND the caller
# didn't explicitly opt out via PAPERFLOW_SKIP_REGISTER=1, fail loud — a
# silent skip here is how docs end up with an unregistered doc_nonce in
# the wild (bridge returns state:'unknown' on /docs/<nonce>/status, and
# doc.js renders that as "Connection state unknown."). Inspection mode
# (user pasting `paperflow-target` output for debugging) must opt in.
if [ -z "$DOC_PATH" ] && [ "${PAPERFLOW_SKIP_REGISTER:-}" != "1" ]; then
  emit_error 3 "register-failed" "No doc_path argument supplied — registration would be skipped silently. Pass the output file path: paperflow-target <doc_path>. To intentionally inspect without registering, set PAPERFLOW_SKIP_REGISTER=1."
fi

if [ "${PAPERFLOW_SKIP_REGISTER:-}" != "1" ] && [ -n "$DOC_PATH" ]; then
  # Consolidated daemon requires session_id in the body (per-instance
  # daemon inferred it from its own context; the shared daemon can't).
  REGISTER_BODY="$(/usr/bin/env jq -n \
    --arg dp  "${DOC_PATH:-}" \
    --arg dn  "$DOC_NONCE" \
    --arg sid "$SESSION_ID" \
    '{doc_path:$dp, doc_nonce:$dn, session_id:$sid}')"

  REGISTER_RESPONSE="$(curl -sS --max-time 3 --fail \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "$REGISTER_BODY" \
    "${BRIDGE_URL}/docs/register" 2>&1)" || {
    emit_error 3 "register-failed" "POST ${BRIDGE_URL}/docs/register failed: ${REGISTER_RESPONSE}"
  }

  # Validate the response — daemon returns {ok:true} on success.
  REGISTER_OK="$(printf '%s' "$REGISTER_RESPONSE" | /usr/bin/env jq -r '.ok // false' 2>/dev/null || echo "false")"
  if [ "$REGISTER_OK" != "true" ]; then
    emit_error 3 "register-failed" "daemon responded but ok!=true: ${REGISTER_RESPONSE}"
  fi
fi

# ── 5. emit target JSON ─────────────────────────────────────────────
if [ "${PAPERFLOW_TARGET_LEGACY:-}" = "1" ]; then
  # Legacy shim — best-effort fill from env. New docs do NOT use these
  # fields; they exist so docs predating the migration keep parsing.
  # B4 (paperflow-8ea) removed the proctree walk that used to populate
  # CLAUDE_PID / CLAUDE_TTY — it was unreliable from subagent contexts
  # and the values are advisory in this shim. The fields stay in the
  # JSON output (as null) so the schema doesn't break.
  CLAUDE_PID=""
  CLAUDE_TTY=""

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
      daemon_url: $url,
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
      daemon_url: $url,
      bridge_url: $url,
      doc_nonce:  $dn,
      session_id: $sid,
      cmux_workspace: (if $ws == "" then null else $ws end)
    }'
fi
