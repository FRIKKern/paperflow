#!/usr/bin/env bash
# PostToolUse hook for Write|Edit:
# If the touched file is an HTML spec/plan under ~/docs/paperflow/ (or the
# legacy ~/docs/superpowers/ symlink, while it still exists during the v2→v3
# deprecation window), open it in the browser via the live-reload URL.
# macOS `open` refocuses an existing tab without duplicating it; live-server
# pushes the WS reload either way.
#
# On cmux, the URL handler returns "OK surface=N placement=reuse|new" so we
# can verify tab-reuse vs new-tab behaviour. Spec v7 § "Tab reuse on cmux"
# requires a debug log; this hook captures stdout from `open` and appends a
# JSON line per invocation to ~/.paperflow/auto-open.log (rotated at 1 MB).

set -e

# Hook input is JSON on stdin.
PAYLOAD="$(cat)"
FILE_PATH="$(printf '%s' "$PAYLOAD" | /usr/bin/env jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)"

[ -n "$FILE_PATH" ] || exit 0

case "$FILE_PATH" in
  */docs/paperflow/specs/*.html|*/docs/paperflow/plans/*.html|*/docs/paperflow/grills/*.html|*/docs/paperflow/notes/*.html|*/docs/paperflow/changelog/*.html|*/docs/paperflow/missions/*.html|*/docs/paperflow/audits/*.html|\
  */docs/superpowers/specs/*.html|*/docs/superpowers/plans/*.html|*/docs/superpowers/grills/*.html|*/docs/superpowers/notes/*.html|*/docs/superpowers/changelog/*.html|*/docs/superpowers/missions/*.html|*/docs/superpowers/audits/*.html)
    # Skip archived audits — re-running an audit on the same site
    # shouldn't accidentally surface an old report from _archive/.
    case "$FILE_PATH" in
      */docs/paperflow/audits/_archive/*|*/docs/superpowers/audits/_archive/*) exit 0 ;;
    esac
    REL="${FILE_PATH#*/docs/}"
    URL="http://localhost:8765/$REL"

    # --- Dispatch: cmux browser surface (preferred) or OS browser (fallback).
    # B3 of paperflow-8hz (cmux-browser-default). Spec §1-3:
    #   ~/docs/paperflow/specs/2026-05-15-paperflow-cmux-integration-spec.html
    # On cmux: route through a shared "paperflow-docs" surface per workspace,
    # lazy-spawned via `cmux browser open <url>`, handle persisted to a
    # workspace-keyed sidecar so subsequent writes navigate via `goto`
    # without re-entering the reuse-or-not lottery.
    # On non-cmux (or any failure): fall back to /usr/bin/open as before.
    # Resolve detect helper: prefer PATH (deploy puts it in ~/.local/bin/),
    # then HOME/.local/bin/ as a backstop, then the source-tree sibling
    # (works when the hook is invoked from a paperflow checkout). The
    # earlier source-tree-only path resolved to ~/.claude/bin/ at deploy
    # time and was never executable, so the hook always fell back to OS
    # browser.
    DETECT_BIN="$(command -v paperflow-cmux-detect 2>/dev/null || true)"
    [ -z "$DETECT_BIN" ] && [ -x "$HOME/.local/bin/paperflow-cmux-detect" ] && DETECT_BIN="$HOME/.local/bin/paperflow-cmux-detect"
    [ -z "$DETECT_BIN" ] && [ -x "$(dirname "$0")/../bin/paperflow-cmux-detect" ] && DETECT_BIN="$(dirname "$0")/../bin/paperflow-cmux-detect"
    DETECT_JSON=""
    CMUX_ON=false
    if [ -n "$DETECT_BIN" ] && [ -x "$DETECT_BIN" ]; then
      # Detect script exits 1 when cmux absent — capture stdout either way.
      DETECT_JSON="$("$DETECT_BIN" 2>/dev/null || true)"
      if [ -n "$DETECT_JSON" ]; then
        CMUX_ON="$(printf '%s' "$DETECT_JSON" | /usr/bin/env jq -r '.cmux // false' 2>/dev/null || echo false)"
      fi
    fi

    RESPONSE=""
    EXIT=0
    DISPATCH="open"  # one of: open | cmux-goto | cmux-spawn | cmux-fallback

    if [ "$CMUX_ON" = "true" ]; then
      WORKSPACE="$(printf '%s' "$DETECT_JSON" | /usr/bin/env jq -r '.workspace // empty' 2>/dev/null || true)"
      CMUX_VER="$(printf '%s' "$DETECT_JSON" | /usr/bin/env jq -r '.version // empty' 2>/dev/null || true)"
      SIDECAR="$HOME/.paperflow/cmux-docs-surface.${WORKSPACE}.handle"
      HANDLE=""

      if [ -n "$WORKSPACE" ] && [ -f "$SIDECAR" ]; then
        HANDLE="$(/usr/bin/env jq -r '.handle // empty' "$SIDECAR" 2>/dev/null || true)"
        SIDE_WS="$(/usr/bin/env jq -r '.workspace // empty' "$SIDECAR" 2>/dev/null || true)"
        # Cross-workspace guard + liveness probe (spec §3).
        if [ -n "$HANDLE" ] && [ "$SIDE_WS" = "$WORKSPACE" ] && \
           cmux browser "$HANDLE" url >/dev/null 2>&1; then
          # Surface alive — navigate.
          RESPONSE="$(cmux browser "$HANDLE" goto "$URL" 2>&1)" || EXIT=$?
          DISPATCH="cmux-goto"
        else
          # Stale — drop sidecar and fall through to spawn.
          trash "$SIDECAR" 2>/dev/null || rm -f "$SIDECAR"
          HANDLE=""
        fi
      fi

      if [ "$DISPATCH" = "open" ] && [ -n "$WORKSPACE" ]; then
        # Lazy spawn. Parse `OK surface=<ref> pane=<ref> placement=<reuse|new>`.
        SPAWN_OUT="$(cmux browser open "$URL" 2>&1)" || SPAWN_RC=$?
        SPAWN_RC="${SPAWN_RC:-0}"
        NEW_HANDLE="$(printf '%s\n' "$SPAWN_OUT" | /usr/bin/awk 'NR==1 { for (i=1;i<=NF;i++) if ($i ~ /^surface=/) { sub(/^surface=/,"",$i); print $i; exit } }')"
        if [ "$SPAWN_RC" = "0" ] && [ -n "$NEW_HANDLE" ]; then
          SPAWN_TS="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
          mkdir -p "$HOME/.paperflow" 2>/dev/null || true
          /usr/bin/env jq -nc \
            --arg handle "$NEW_HANDLE" \
            --arg workspace "$WORKSPACE" \
            --arg spawned_at "$SPAWN_TS" \
            --arg cmux_version "$CMUX_VER" \
            '{handle:$handle, workspace:$workspace, spawned_at:$spawned_at, cmux_version:$cmux_version}' \
            > "$SIDECAR" 2>/dev/null || true
          RESPONSE="$SPAWN_OUT"
          EXIT="$SPAWN_RC"
          DISPATCH="cmux-spawn"
        else
          # Spawn failed or no surface= token — fall through to OS browser.
          RESPONSE="cmux browser open failed (rc=$SPAWN_RC): $SPAWN_OUT"
          DISPATCH="cmux-fallback"
        fi
      fi
    fi

    if [ "$DISPATCH" = "open" ] || [ "$DISPATCH" = "cmux-fallback" ]; then
      # OS browser. Captures cmux URL-handler stdout too on non-paperflow cmux
      # tabs ("OK surface=N placement=…"); the log entry records ts/url.
      OS_RESPONSE="$(/usr/bin/open "$URL" 2>&1)" || EXIT=$?
      # Preserve any prior cmux failure context by prepending it to the response.
      if [ -n "$RESPONSE" ]; then
        RESPONSE="$RESPONSE | os-open: $OS_RESPONSE"
      else
        RESPONSE="$OS_RESPONSE"
      fi
    fi
    EXIT="${EXIT:-0}"

    LOG_DIR="$HOME/.paperflow"
    LOG_FILE="$LOG_DIR/auto-open.log"
    mkdir -p "$LOG_DIR"

    # Rotate at 1 MB. `stat -f%z` on macOS, `stat -c%s` on Linux — paperflow
    # is macOS-only, so use the BSD form.
    if [ -f "$LOG_FILE" ]; then
      SIZE="$(/usr/bin/stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
      if [ "$SIZE" -gt 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.1"
      fi
    fi

    TS="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    # JSON-escape the response (newlines, quotes, backslashes) via jq so a
    # cmux response with embedded characters can't corrupt the log.
    /usr/bin/env jq -nc \
      --arg ts "$TS" \
      --arg url "$URL" \
      --arg response "$RESPONSE" \
      --arg dispatch "$DISPATCH" \
      --argjson exit "$EXIT" \
      '{ts: $ts, url: $url, dispatch: $dispatch, response: $response, exit: $exit}' \
      >> "$LOG_FILE" 2>/dev/null || true

    # Surface doctor status to the dock by READING the cache, never by
    # invoking paperflow-doctor — `--fast` re-execs as `--full` when the
    # cache is stale, which adds 1-5s to the user's interactive doc-save
    # loop. The cache is refreshed by explicit `paperflow-doctor` runs
    # (manual, /paperflow:install, or scheduled). All errors swallowed.
    CACHE="$HOME/.paperflow/doctor.cache.json"
    if [ -f "$CACHE" ]; then
      DR_W="$(/usr/bin/env jq -r '[.issues[]? | select(.severity=="warning")] | length' "$CACHE" 2>/dev/null || echo 0)"
      DR_C="$(/usr/bin/env jq -r '[.issues[]? | select(.severity=="critical")] | length' "$CACHE" 2>/dev/null || echo 0)"
      if [ "$DR_C" != "0" ]; then
        DR_MSG="$(printf 'doctor: %s critical, %s warning(s) — run paperflow-doctor --full' "$DR_C" "$DR_W")"
      elif [ "$DR_W" != "0" ]; then
        DR_MSG="$(printf 'doctor: %s warning(s) — run paperflow-doctor --full' "$DR_W")"
      else
        DR_MSG="doctor: ok"
      fi
    else
      DR_MSG="doctor: not yet run (paperflow-doctor --full)"
    fi
    FEED_DIR="$HOME/.paperflow/dock-feeds"
    mkdir -p "$FEED_DIR" 2>/dev/null || true
    FEED_FILE="$FEED_DIR/doctor-status"
    # Diff-check: only rewrite when content changes — saves spurious mtime
    # bumps that would wake any dock watcher tailing the file.
    if [ "$DR_MSG" != "$(cat "$FEED_FILE" 2>/dev/null)" ]; then
      printf '%s\n' "$DR_MSG" > "$FEED_FILE"
    fi
    ;;
esac

exit 0
