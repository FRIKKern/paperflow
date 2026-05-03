#!/usr/bin/env bash
# PostToolUse hook for Write|Edit:
# If the touched file is an HTML spec/plan under ~/docs/superpowers/, open it
# in the browser via the live-reload URL. macOS `open` refocuses an existing
# tab without duplicating it; live-server pushes the WS reload either way.

set -e

# Hook input is JSON on stdin.
PAYLOAD="$(cat)"
FILE_PATH="$(printf '%s' "$PAYLOAD" | /usr/bin/env jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)"

[ -n "$FILE_PATH" ] || exit 0

case "$FILE_PATH" in
  */docs/superpowers/specs/*.html|*/docs/superpowers/plans/*.html|*/docs/superpowers/grills/*.html|*/docs/superpowers/notes/*.html|*/docs/superpowers/changelog/*.html|*/docs/superpowers/missions/*.html)
    REL="${FILE_PATH#*/docs/}"
    /usr/bin/open "http://localhost:8765/$REL" >/dev/null 2>&1 || true
    ;;
esac

exit 0
