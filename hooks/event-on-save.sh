#!/usr/bin/env bash
# PostToolUse hook for Write|Edit:
# When the touched file is a paperflow doc HTML AND a Goal is active in the
# repo containing the file, POST to barkpark's /v1/paperflow/papers ingest
# (default http://localhost:4000, overridable via BARKPARK_INGEST_URL in
# ~/.paperflow/barkpark.env) with {slug, event_type, source_doc, body_html,
# goal_id?, parent_event?}. Barkpark upserts the paper and, because
# event_type is non-empty, appends a paper_events row as a side-effect
# (Barkpark.Content.maybe_append_paper_event/3) — that row is what the
# goal-path rail reads back. The legacy claude-bridge:8766/event route was
# retired with the convergence MVP and the standalone aux-daemon is a
# deprecated shim past its grace period.
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

# Source the Barkpark pairing file early so this event POST lands at the
# same endpoint as the mirror block below. The legacy aux-daemon on :8766
# was retired with the convergence MVP; barkpark's POST /v1/paperflow/papers
# upserts the paper AND appends a paper_events row as a side-effect whenever
# `event_type` is non-empty (see Barkpark.Content.maybe_append_paper_event/3).
# A second event-only route is not provided — this is the documented contract.
BARKPARK_ENV_FILE="$HOME/.paperflow/barkpark.env"
if [ -z "${BARKPARK_INGEST_URL:-}" ] && [ -f "$BARKPARK_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$BARKPARK_ENV_FILE" 2>/dev/null || true
fi
EVENT_INGEST_URL="${BARKPARK_INGEST_URL:-http://localhost:4000/v1/paperflow/papers}"
EVENT_SLUG="$(/usr/bin/basename "$FILE_PATH" .html)"

# Build JSON body via jq so quoting/newlines survive. When GOAL_ID is empty
# the save is "attributed-while-detached" — barkpark treats a missing goal_id
# as an unattributed event row (no FK enforcement, just stored as NULL).
# `slug` + `body_html` are the required keys for /v1/paperflow/papers; the
# `event_type` side-effect appends the paper_events row.
BODY="$(/usr/bin/env jq -nc \
  --arg slug       "$EVENT_SLUG" \
  --arg goal_id    "$GOAL_ID" \
  --arg event_type "$EVT" \
  --arg source_doc "$SRC_REL" \
  --arg parent     "$PARENT_EVENT" \
  --arg payload    "$PAYLOAD_HTML" \
  '{slug: $slug, event_type: $event_type, source_doc: $source_doc, body_html: $payload}
   + (if $goal_id != "" then {goal_id: $goal_id} else {detached: true} end)
   + (if $parent  != "" then {parent_event: $parent} else {} end)' 2>/dev/null || true)"

[ -n "$BODY" ] || exit 0

# ── POST to barkpark. 2s timeout — never block the write hook. Bearer token
# optional (matches the mirror block contract: when unset, barkpark's
# RequireIngestToken plug rejects 401 and the hook silently moves on).
set -- /usr/bin/curl -s --max-time 2 \
  -H 'Content-Type: application/json'
if [ -n "${BARKPARK_INGEST_TOKEN:-}" ]; then
  set -- "$@" -H "Authorization: Bearer ${BARKPARK_INGEST_TOKEN}"
fi
RESP="$("$@" --data-binary "$BODY" "$EVENT_INGEST_URL" 2>/dev/null || true)"

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

# ── Barkpark mirror (convergence MVP, masterplan Figure 5 S2 / Figure 6) ──
# When --with-barkpark is enabled, mirror the saved paper into the LOCAL
# Barkpark so it opens inside a Phoenix LiveView (no reload, by construction)
# instead of the cmux goto-reload that auto-open-doc.sh would otherwise do.
#
# Enablement signal (reuse U5's contract — do NOT invent a new env name):
#   - $BARKPARK_INGEST_URL already in the environment, OR
#   - ~/.paperflow/barkpark.env exists (written by install.sh --with-barkpark)
#     and is sourced here to populate BARKPARK_INGEST_URL / BARKPARK_INGEST_TOKEN.
# When neither is present, this block is a complete no-op and the original
# cmux/auto-open path runs unchanged — no regression.
#
# Defensive throughout: extract-body failure, an unreachable Barkpark, or a
# missing `open` all log + fall back. The doc has already landed on disk; this
# seam must NEVER break the save.
BARKPARK_ENV_FILE="$HOME/.paperflow/barkpark.env"
if [ -z "${BARKPARK_INGEST_URL:-}" ] && [ -f "$BARKPARK_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$BARKPARK_ENV_FILE" 2>/dev/null || true
fi

if [ -n "${BARKPARK_INGEST_URL:-}" ]; then
  # ── Single repointable variables. The Barkpark ingest endpoint and the
  # ── LiveView surface do not exist yet (a later barkpark unit builds them);
  # ── these two lines are the only thing to touch when that side lands.
  BARKPARK_INGEST_ENDPOINT="$BARKPARK_INGEST_URL"          # POST target for the body
  BARKPARK_LIVEVIEW_PATH_TEMPLATE="/papers/{slug}"          # LiveView route; {slug} substituted

  # Derive the LiveView base (scheme://host[:port]) from the ingest URL so a
  # single env edit repoints both ingest and view. Strip everything from the
  # first slash after the authority. Falls back to the dev default if the URL
  # is malformed.
  BARKPARK_ORIGIN="$(printf '%s' "$BARKPARK_INGEST_ENDPOINT" \
    | /usr/bin/sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://[^/]+).*#\1#')"
  case "$BARKPARK_ORIGIN" in
    *://*) ;;                                  # looks like scheme://authority
    *) BARKPARK_ORIGIN="http://localhost:4000" ;;
  esac

  # Doc identity available at the seam: relative path, slug, goal id.
  BP_SRC_REL="$SRC_REL"
  BP_SLUG="$(/usr/bin/basename "$FILE_PATH" .html)"
  BP_GOAL_ID="$GOAL_ID"
  # Fill {slug} via shell parameter expansion (NOT sed) — a slug containing
  # sed metacharacters (& # \) would otherwise corrupt or break the command.
  BP_LIVEVIEW_PATH="${BARKPARK_LIVEVIEW_PATH_TEMPLATE//\{slug\}/$BP_SLUG}"
  BP_LIVEVIEW_URL="${BARKPARK_ORIGIN}${BP_LIVEVIEW_PATH}"

  BP_LOG_DIR="$HOME/.paperflow"
  /bin/mkdir -p "$BP_LOG_DIR" 2>/dev/null || true
  BP_LOG="$BP_LOG_DIR/barkpark-mirror.log"
  bp_log() {
    /usr/bin/env jq -nc \
      --arg ts "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg event "$1" \
      --arg slug "$BP_SLUG" \
      --arg src "$BP_SRC_REL" \
      --arg goal "$BP_GOAL_ID" \
      --arg url "$BP_LIVEVIEW_URL" \
      --arg detail "${2:-}" \
      '{ts:$ts, event:$event, slug:$slug, source:$src, goal:$goal, liveview_url:$url, detail:$detail}' \
      >> "$BP_LOG" 2>/dev/null || true
  }

  # 1. Extract the clean article body (strips the doc.js / CLAUDE_TARGET tail).
  #    Resolve the helper from PATH, then ~/.local/bin, then the source tree —
  #    mirrors the resolution other paperflow hooks use.
  EXTRACT_BIN="$(command -v paperflow-extract-body 2>/dev/null || true)"
  [ -z "$EXTRACT_BIN" ] && [ -x "$HOME/.local/bin/paperflow-extract-body" ] && EXTRACT_BIN="$HOME/.local/bin/paperflow-extract-body"
  [ -z "$EXTRACT_BIN" ] && [ -x "$(/usr/bin/dirname "$0")/../bin/paperflow-extract-body" ] && EXTRACT_BIN="$(/usr/bin/dirname "$0")/../bin/paperflow-extract-body"

  BP_BODY=""
  if [ -n "$EXTRACT_BIN" ] && [ -x "$EXTRACT_BIN" ]; then
    BP_BODY="$("$EXTRACT_BIN" "$FILE_PATH" 2>/dev/null || true)"
  fi

  # ── 1b. NATIVE portable-doc blocks (P5 automate) ──────────────────────────
  # For article-grammar paperflow docs, convert the HTML to native portable-doc
  # blocks and POST {slug, style:"article", blocks} so Barkpark renders the doc
  # natively in article mode at /papers/:slug — instead of storing raw
  # body_html. Grills and questionnaires use a different (form) grammar and are
  # OUT OF SCOPE: they keep the legacy body_html mirror untouched.
  #
  # CRITICAL ROBUSTNESS: if the converter is missing, errors, or yields no
  # blocks, BP_BLOCKS stays empty and we fall through to the body_html path
  # below — the save is never broken. The converter is resolved the same way
  # as paperflow-extract-body (PATH → ~/.local/bin → source tree).
  BP_BLOCKS=""
  case "$EVT" in
    grill-written|questionnaire-written)
      # Form grammar — out of scope. Leave BP_BLOCKS empty → body_html path.
      : ;;
    *)
      BLOCKS_BIN="$(command -v paperflow-to-blocks 2>/dev/null || true)"
      [ -z "$BLOCKS_BIN" ] && [ -x "$HOME/.local/bin/paperflow-to-blocks" ] && BLOCKS_BIN="$HOME/.local/bin/paperflow-to-blocks"
      [ -z "$BLOCKS_BIN" ] && [ -x "$(/usr/bin/dirname "$0")/../bin/paperflow-to-blocks" ] && BLOCKS_BIN="$(/usr/bin/dirname "$0")/../bin/paperflow-to-blocks"
      if [ -n "$BLOCKS_BIN" ] && [ -x "$BLOCKS_BIN" ]; then
        # Emit just the blocks array. A non-empty JSON array ("[ … ]" with at
        # least one element) is the gate; anything else (converter error, empty
        # doc, "[]") falls through. jq validates the shape so a partial/garbled
        # stdout can't reach Barkpark.
        BP_BLOCKS_RAW="$("$BLOCKS_BIN" "$FILE_PATH" --blocks 2>/dev/null || true)"
        if [ -n "$BP_BLOCKS_RAW" ]; then
          BP_BLOCKS="$(printf '%s' "$BP_BLOCKS_RAW" \
            | /usr/bin/env jq -c 'if (type=="array" and length>0) then . else empty end' 2>/dev/null || true)"
        fi
      fi
      ;;
  esac

  if [ -n "$BP_BLOCKS" ]; then
    # ── Native-blocks POST. Build {slug, style:"article", blocks, …} and POST
    # ── to the SAME ingest endpoint. Bearer token optional. On any failure
    # ── (jq build, unreachable, non-2xx) we log and STILL try to open the
    # ── LiveView; the doc is already on disk. exit 0 always.
    BP_REQ_BODY="$(/usr/bin/env jq -nc \
      --arg source_doc "$BP_SRC_REL" \
      --arg slug       "$BP_SLUG" \
      --arg goal_id    "$BP_GOAL_ID" \
      --arg event_type "$EVT" \
      --argjson blocks "$BP_BLOCKS" \
      '{source_doc:$source_doc, slug:$slug, event_type:$event_type, style:"article", blocks:$blocks}
       + (if $goal_id != "" then {goal_id:$goal_id} else {} end)' 2>/dev/null || true)"

    if [ -n "$BP_REQ_BODY" ]; then
      set -- /usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
        -H 'Content-Type: application/json'
      if [ -n "${BARKPARK_INGEST_TOKEN:-}" ]; then
        set -- "$@" -H "Authorization: Bearer ${BARKPARK_INGEST_TOKEN}"
      fi
      set -- "$@" --data-binary "$BP_REQ_BODY" "$BARKPARK_INGEST_ENDPOINT"

      if [ "${PAPERFLOW_DRYRUN:-0}" = "1" ]; then
        bp_log "dryrun-post-blocks" "POST ${BARKPARK_INGEST_ENDPOINT} (native blocks)"
        BP_OK=1
      else
        BP_CODE="$("$@" 2>/dev/null || true)"
        case "$BP_CODE" in
          2*)
            BP_OK=1
            bp_log "ingest-blocks-ok" "POST ${BARKPARK_INGEST_ENDPOINT} -> ${BP_CODE} (native blocks)" ;;
          *)
            BP_OK=0
            bp_log "ingest-blocks-failed" "POST ${BARKPARK_INGEST_ENDPOINT} -> ${BP_CODE:-no-response} — doc still on disk" ;;
        esac
      fi

      : "$BP_OK"  # not a control gate — surface the LiveView either way
      if [ "${PAPERFLOW_DRYRUN:-0}" = "1" ]; then
        bp_log "dryrun-open" "open ${BP_LIVEVIEW_URL}"
      else
        if /usr/bin/open "$BP_LIVEVIEW_URL" >/dev/null 2>&1; then
          bp_log "open-ok" "open ${BP_LIVEVIEW_URL}"
        else
          bp_log "open-failed" "could not open ${BP_LIVEVIEW_URL}"
        fi
      fi
    else
      # jq could not assemble the native body — fall back to body_html below.
      bp_log "blocks-request-build-failed" "jq could not assemble the native-blocks body; falling back to body_html"
      BP_BLOCKS=""
    fi
  fi

  if [ -n "$BP_BLOCKS" ]; then
    # Native path already handled the mirror + open above — skip the legacy
    # body_html block entirely.
    :
  elif [ -z "$BP_BODY" ]; then
    # Defensive: no body (helper missing or empty) — log and fall back to the
    # original cmux/auto-open path by NOT suppressing it (see suppress flag).
    bp_log "extract-failed" "paperflow-extract-body unresolved or produced empty body"
  else
    # 2. POST the body + identity to the local Barkpark ingest URL. jq builds
    #    the JSON so the body's quotes/newlines survive. Bearer token optional.
    BP_REQ_BODY="$(/usr/bin/env jq -nc \
      --arg source_doc "$BP_SRC_REL" \
      --arg slug       "$BP_SLUG" \
      --arg goal_id    "$BP_GOAL_ID" \
      --arg event_type "$EVT" \
      --arg body_html  "$BP_BODY" \
      '{source_doc:$source_doc, slug:$slug, event_type:$event_type, body_html:$body_html}
       + (if $goal_id != "" then {goal_id:$goal_id} else {} end)' 2>/dev/null || true)"

    if [ -n "$BP_REQ_BODY" ]; then
      # Build curl argv. PAPERFLOW_DRYRUN=1 echoes the curl invocation to the
      # log INSTEAD of running it — the documented dry-run hook for tests
      # (the Barkpark server does not exist yet, so this is the only way to
      # exercise the path). 2s timeout — never block the save.
      set -- /usr/bin/curl -s --max-time 2 \
        -H 'Content-Type: application/json'
      if [ -n "${BARKPARK_INGEST_TOKEN:-}" ]; then
        set -- "$@" -H "Authorization: Bearer ${BARKPARK_INGEST_TOKEN}"
      fi
      set -- "$@" --data-binary "$BP_REQ_BODY" "$BARKPARK_INGEST_ENDPOINT"

      if [ "${PAPERFLOW_DRYRUN:-0}" = "1" ]; then
        # Dry-run: record that extract-body ran (body non-empty) and the exact
        # POST target, without hitting the network.
        bp_log "dryrun-post" "POST ${BARKPARK_INGEST_ENDPOINT}"
        BP_OK=1
      else
        if "$@" >/dev/null 2>&1; then
          BP_OK=1
          bp_log "ingest-ok" "POST ${BARKPARK_INGEST_ENDPOINT}"
        else
          BP_OK=0
          bp_log "ingest-failed" "Barkpark unreachable at ${BARKPARK_INGEST_ENDPOINT} — doc still on disk"
        fi
      fi

      # 3. Open the Barkpark LiveView URL INSTEAD of the cmux goto-reload.
      #    auto-open-doc.sh independently detects the same U5 enablement signal
      #    and bows out (it runs FIRST in PostToolUse order, so a per-file
      #    handshake here couldn't gate it anyway) — the LiveView is the
      #    surface. Here we just open it. BP_OK is unused for branching: even
      #    if the ingest POST failed (Barkpark unreachable) we still try to
      #    surface the LiveView; if THAT fails too we log and the doc remains
      #    on disk. The save is never broken.
      : "$BP_OK"  # retained for log/debugging symmetry; not a control gate
      if [ "${PAPERFLOW_DRYRUN:-0}" = "1" ]; then
        bp_log "dryrun-open" "open ${BP_LIVEVIEW_URL}"
      else
        if /usr/bin/open "$BP_LIVEVIEW_URL" >/dev/null 2>&1; then
          bp_log "open-ok" "open ${BP_LIVEVIEW_URL}"
        else
          bp_log "open-failed" "could not open ${BP_LIVEVIEW_URL}"
        fi
      fi
    else
      bp_log "request-build-failed" "jq could not assemble the ingest body"
    fi
  fi
fi

exit 0
