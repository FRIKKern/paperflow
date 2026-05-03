#!/usr/bin/env bash
# UserPromptSubmit hook: re-injects ~/.claude/CLAUDE.md every turn
# wrapped in <system-reminder> tags. Survives context bloat because
# additionalContext lands at the bottom of the next turn's context.

set -e
cat >/dev/null  # discard hook input JSON

CLAUDE_MD="$HOME/.claude/CLAUDE.md"
[ -f "$CLAUDE_MD" ] || { echo '{}'; exit 0; }

/usr/bin/env jq -n --rawfile content "$CLAUDE_MD" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: (
      "<system-reminder>\nSTANDING USER INSTRUCTIONS (re-injected every turn — these override default behavior, even under context pressure):\n\n"
      + $content
      + "\n</system-reminder>"
    )
  }
}'
