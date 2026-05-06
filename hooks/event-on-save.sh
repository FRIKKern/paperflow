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

# ── Resolve the active-goal pointer in three strategies (first hit wins):
#   1. Walk up from the saved file's directory looking for
#      `.paperflow/active-goal`. Catches docs that live INSIDE a repo
#      that uses paperflow.
#   2. Walk up from $PWD (the shell's cwd, which when paperflow is being
#      driven by the orchestrator is the dev repo root).
#   3. Fall back to ~/.paperflow/active-goal — a global pointer the
#      paperflow-goal skill mirrors on open and clears on close.
# If none resolves, the rail can't render anyway, so quiet exit 0.
walk_up_for_active_goal() {
  local dir="$1"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.paperflow/active-goal" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(/usr/bin/dirname "$dir")"
  done
  return 1
}

REPO_DIR=""
ACTIVE_GOAL_FILE=""

# Strategy 1: walk up from the saved file's directory.
REPO_DIR="$(walk_up_for_active_goal "$(/usr/bin/dirname "$FILE_PATH")" || true)"
if [ -n "$REPO_DIR" ]; then
  ACTIVE_GOAL_FILE="$REPO_DIR/.paperflow/active-goal"
fi

# Strategy 2: walk up from $PWD.
if [ -z "$ACTIVE_GOAL_FILE" ] && [ -n "$PWD" ]; then
  REPO_DIR="$(walk_up_for_active_goal "$PWD" || true)"
  if [ -n "$REPO_DIR" ]; then
    ACTIVE_GOAL_FILE="$REPO_DIR/.paperflow/active-goal"
  fi
fi

# Strategy 3: global fallback.
if [ -z "$ACTIVE_GOAL_FILE" ] && [ -f "$HOME/.paperflow/active-goal" ]; then
  ACTIVE_GOAL_FILE="$HOME/.paperflow/active-goal"
  REPO_DIR="$HOME"
fi

if [ -z "$ACTIVE_GOAL_FILE" ]; then
  # No active Goal anywhere — the rail wouldn't render anyway.
  exit 0
fi

GOAL_ID="$(/usr/bin/head -n1 "$ACTIVE_GOAL_FILE" | /usr/bin/tr -d '[:space:]')"
[ -n "$GOAL_ID" ] || exit 0

# Optional walk-back parent. If non-empty, we forward it so the bridge can
# label the event and start a fresh branch.
PARENT_EVENT=""
if [ -f "$REPO_DIR/.paperflow/active-event-base" ]; then
  PARENT_EVENT="$(/usr/bin/head -n1 "$REPO_DIR/.paperflow/active-event-base" | /usr/bin/tr -d '[:space:]')"
fi

# ── Build the source_doc relative path (drop the leading absolute prefix
# ── so the label reads e.g. "plans/2026-05-06-foo.html").
SRC_REL="${FILE_PATH#*/docs/paperflow/}"
case "$SRC_REL" in /*|*/*) ;; *) SRC_REL="${FILE_PATH#*/docs/superpowers/}" ;; esac

# Read payload — the saved HTML — into the JSON body via jq, which will
# escape newlines/quotes correctly. Cap at ~512 KB to avoid bloating bd.
PAYLOAD_HTML="$(/usr/bin/head -c 524288 "$FILE_PATH" 2>/dev/null || true)"

# Build JSON body via jq so quoting/newlines survive.
BODY="$(/usr/bin/env jq -nc \
  --arg goal_id    "$GOAL_ID" \
  --arg event_type "$EVT" \
  --arg source_doc "$SRC_REL" \
  --arg parent     "$PARENT_EVENT" \
  --arg payload    "$PAYLOAD_HTML" \
  '{goal_id: $goal_id, event_type: $event_type, source_doc: $source_doc}
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
