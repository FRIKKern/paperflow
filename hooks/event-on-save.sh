#!/usr/bin/env bash
# PostToolUse hook for Write|Edit:
# When the touched file is a paperflow doc HTML AND a Goal is active in the
# repo containing the file, POST to claude-bridge:8766/event with
# {goal_id, event_type, source_doc, parent_event?, payload_html}. The bridge
# creates a kind:event Beads task under the goal-task and writes the
# sidecar HTML to ~/.paperflow/events/<event-id>.html.
#
# Quiet on success. Quiet on "no active goal" (the rail just won't render
# until the user opens a Goal). Errors print to stderr but never block the
# write.

set -e

PAYLOAD="$(cat)"
FILE_PATH="$(printf '%s' "$PAYLOAD" | /usr/bin/env jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)"

[ -n "$FILE_PATH" ] || exit 0
[ -f "$FILE_PATH" ] || exit 0   # only react to actual files

# ── Path allowlist — same set as validate-paperflow-doc.sh, plus the
# ── questionnaires/ + goals/ subdirectories the rail also tracks. Out of
# ── tree files are silently ignored.
case "$FILE_PATH" in
  */docs/paperflow/specs/*.html|\
  */docs/paperflow/plans/*.html|\
  */docs/paperflow/grills/*.html|\
  */docs/paperflow/questionnaires/*.html|\
  */docs/paperflow/goals/*/*.html|\
  */docs/paperflow/changelog/*.html|\
  */docs/paperflow/audits/*.html|\
  */docs/superpowers/specs/*.html|\
  */docs/superpowers/plans/*.html|\
  */docs/superpowers/grills/*.html|\
  */docs/superpowers/questionnaires/*.html|\
  */docs/superpowers/goals/*/*.html|\
  */docs/superpowers/changelog/*.html|\
  */docs/superpowers/audits/*.html)
    ;;
  *) exit 0 ;;
esac

# Skip archived audits.
case "$FILE_PATH" in
  */audits/_archive/*) exit 0 ;;
esac

# ── Determine event_type from the doc kind (path segment).
case "$FILE_PATH" in
  */specs/*)          EVT="spec-written" ;;
  */plans/*)          EVT="plan-written" ;;
  */grills/*)         EVT="grill-written" ;;
  */questionnaires/*) EVT="questionnaire-written" ;;
  */goals/*)          EVT="goal-snapshot" ;;
  */changelog/*)      EVT="changelog-written" ;;
  */audits/*)         EVT="audit-written" ;;
  *)                  EVT="doc-written" ;;
esac

# ── Resolve the active-goal pointer via paperflow-active-scope. The helper
# owns the scope priority chain (cmux workspace → CLAUDE_SESSION_ID → unscoped
# legacy fallback) plus its own PID-keyed cache. Pull the session_id out of
# the JSON payload and pass it through $CLAUDE_SESSION_ID so the helper can
# skip cmux identify on the hook hot path when the session id is already
# known. If the resolver returns empty, the save is "detached":
#   - paperflow doc under ~/docs/paperflow/... → record the event without a
#     parent goal (free-floating "attributed-while-detached"); bridge handles
#     the no-parent case.
#   - non-paperflow file → already filtered out above.
SCOPE_HELPER="$HOME/.local/bin/paperflow-active-scope"
[ -x "$SCOPE_HELPER" ] || SCOPE_HELPER="$(command -v paperflow-active-scope 2>/dev/null || true)"

CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID:-$(printf '%s' "$PAYLOAD" | /usr/bin/env jq -r '.session_id // empty' 2>/dev/null || true)}"
export CLAUDE_SESSION_ID

GOAL_ID=""
if [ -n "$SCOPE_HELPER" ]; then
  GOAL_ID="$(CLAUDE_SESSION_ID="$CLAUDE_SESSION_ID" "$SCOPE_HELPER" --read goal 2>/dev/null || true)"
fi

# Optional walk-back parent. The pointer is per-repo; locate the nearest
# .paperflow/ above the saved file or $PWD.
PARENT_EVENT=""
REPO_DIR=""
walk_up_for_event_base() {
  local dir="$1"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.paperflow/active-event-base" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(/usr/bin/dirname "$dir")"
  done
  return 1
}
REPO_DIR="$(walk_up_for_event_base "$(/usr/bin/dirname "$FILE_PATH")" || true)"
[ -z "$REPO_DIR" ] && [ -n "$PWD" ] && REPO_DIR="$(walk_up_for_event_base "$PWD" || true)"
if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/.paperflow/active-event-base" ]; then
  PARENT_EVENT="$(/usr/bin/head -n1 "$REPO_DIR/.paperflow/active-event-base" | /usr/bin/tr -d '[:space:]')"
fi

# ── Build the source_doc relative path (drop the leading absolute prefix
# ── so the label reads e.g. "plans/2026-05-06-foo.html").
SRC_REL="${FILE_PATH#*/docs/paperflow/}"
case "$SRC_REL" in /*|*/*) ;; *) SRC_REL="${FILE_PATH#*/docs/superpowers/}" ;; esac

# Read payload — the saved HTML — into the JSON body via jq, which will
# escape newlines/quotes correctly. Cap at ~512 KB to avoid bloating bd.
PAYLOAD_HTML="$(/usr/bin/head -c 524288 "$FILE_PATH" 2>/dev/null || true)"

# Build JSON body via jq so quoting/newlines survive. When GOAL_ID is empty
# the save is "attributed-while-detached" — the bridge handles the no-parent
# case by labelling the event accordingly.
BODY="$(/usr/bin/env jq -nc \
  --arg goal_id    "$GOAL_ID" \
  --arg event_type "$EVT" \
  --arg source_doc "$SRC_REL" \
  --arg parent     "$PARENT_EVENT" \
  --arg payload    "$PAYLOAD_HTML" \
  '{event_type: $event_type, source_doc: $source_doc}
   + (if $goal_id != "" then {goal_id: $goal_id} else {detached: true} end)
   + (if $parent  != "" then {parent_event: $parent} else {} end)
   + (if $payload != "" then {payload_html: $payload} else {} end)' 2>/dev/null || true)"

[ -n "$BODY" ] || exit 0

# ── POST to bridge. 2s timeout — never block the write hook.
RESP="$(/usr/bin/curl -s --max-time 2 \
  -H 'Content-Type: application/json' \
  --data-binary "$BODY" \
  http://127.0.0.1:8766/event 2>/dev/null || true)"

# ── Optional: if the active-event-base was set AND the request succeeded,
# ── log to ~/.paperflow/event-log.jsonl (separate from auto-open.log).
if [ -n "$PARENT_EVENT" ] && [ -n "$RESP" ]; then
  EID="$(printf '%s' "$RESP" | /usr/bin/env jq -r '.event_id // empty' 2>/dev/null)"
  if [ -n "$EID" ]; then
    LOG_DIR="$HOME/.paperflow"
    /bin/mkdir -p "$LOG_DIR" 2>/dev/null || true
    TS="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    /usr/bin/env jq -nc \
      --arg ts "$TS" \
      --arg goal "$GOAL_ID" \
      --arg event "$EID" \
      --arg parent "$PARENT_EVENT" \
      --arg src "$SRC_REL" \
      '{ts: $ts, goal: $goal, event: $event, parent_event: $parent, source: $src, branched: true}' \
      >> "$LOG_DIR/event-log.jsonl" 2>/dev/null || true

    # Clear the pointer — branch was created, the next save returns to the
    # head of `main`. Spec figure 5.
    : > "$REPO_DIR/.paperflow/active-event-base" 2>/dev/null || true
  fi
fi

exit 0
