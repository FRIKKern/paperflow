#!/usr/bin/env bash
# PostToolUse hook for Write|Edit:
# If the touched file is a paperflow doc HTML, run paperflow-validate.
# On Mermaid syntax error, emit additionalContext via the hook output JSON
# so Claude sees a system-reminder and can fix the offending block before
# reporting the URL to the user. Quiet on success.

set -e

PAYLOAD="$(cat)"
FILE_PATH="$(printf '%s' "$PAYLOAD" | /usr/bin/env jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)"

[ -n "$FILE_PATH" ] || exit 0

case "$FILE_PATH" in
  */docs/superpowers/specs/*.html|\
  */docs/superpowers/plans/*.html|\
  */docs/superpowers/grills/*.html|\
  */docs/superpowers/notes/*.html|\
  */docs/superpowers/changelog/*.html|\
  */docs/superpowers/missions/*.html|\
  */docs/superpowers/audits/*.html)
    ;;
  *)
    exit 0 ;;
esac

VALIDATOR="$HOME/.local/bin/paperflow-validate"
[ -x "$VALIDATOR" ] || exit 0   # if validator missing, fail open

if RESULT="$("$VALIDATOR" "$FILE_PATH" 2>/dev/null)"; then
  exit 0   # ok=true
fi

# Non-zero exit → at least one Mermaid block failed to parse.
# Emit hookSpecificOutput.additionalContext with a sharp reminder.
COUNT="$(printf '%s' "$RESULT" | /usr/bin/env jq -r '.failed | length' 2>/dev/null || echo "?")"
SUMMARY="$(printf '%s' "$RESULT" | /usr/bin/env jq -r '
  .failed | map(
    "  - " + (.kind // "?") +
    (if .qid then " (" + .qid + ")" else "" end) +
    " line~" + (.line_estimate|tostring) + ": " +
    (.error_message | split("\n")[0])
  ) | .[]
' 2>/dev/null || echo "")"

MSG="The doc you just wrote/edited at $FILE_PATH has $COUNT Mermaid block(s) that fail to parse and will render as the bomb-icon \"Syntax error in text\" in the browser. Run \`paperflow-validate $FILE_PATH\` for full details, then fix the offending blocks before reporting the URL to the user."
[ -n "$SUMMARY" ] && MSG="$MSG"$'\n\nFailed blocks:\n'"$SUMMARY"

/usr/bin/env jq -n --arg msg "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $msg
  }
}'

exit 0
