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

    # Capture stdout + stderr from `open`. cmux's URL handler emits a line
    # like "OK surface=2 placement=reuse" — useful for debugging tab-reuse.
    # On non-cmux Macs `open` is silent; the log entry still records ts/url.
    RESPONSE="$(/usr/bin/open "$URL" 2>&1)" || EXIT=$?
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
      --argjson exit "$EXIT" \
      '{ts: $ts, url: $url, response: $response, exit: $exit}' \
      >> "$LOG_FILE" 2>/dev/null || true
    ;;
esac

exit 0
