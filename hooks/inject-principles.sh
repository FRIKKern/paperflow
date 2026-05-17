#!/usr/bin/env bash
# UserPromptSubmit hook: re-injects ~/.claude/CLAUDE.md every turn
# wrapped in <system-reminder> tags. Survives context bloat because
# additionalContext lands at the bottom of the next turn's context.
#
# Smart about cmux: when not running under cmux, every block bracketed
# by <!-- paperflow:cmux-only:begin --> / <!-- paperflow:cmux-only:end -->
# is stripped before injection — saves tokens and avoids guidance the
# user can't act on. Detection delegates to paperflow-cmux-detect.

set -e
cat >/dev/null  # discard hook input JSON

CLAUDE_MD="$HOME/.claude/CLAUDE.md"
[ -f "$CLAUDE_MD" ] || { echo '{}'; exit 0; }

# Detect cmux availability. Strip cmux-only blocks when absent.
# paperflow-cmux-detect is small + fast (~50ms); running it per-turn is
# cheap and avoids per-session marker complexity.
CMUX_ON=false
DETECT_BIN="$(command -v paperflow-cmux-detect 2>/dev/null || true)"
[ -z "$DETECT_BIN" ] && [ -x "$HOME/.local/bin/paperflow-cmux-detect" ] \
    && DETECT_BIN="$HOME/.local/bin/paperflow-cmux-detect"
if [ -n "$DETECT_BIN" ] && [ -x "$DETECT_BIN" ]; then
    CMUX_ON="$("$DETECT_BIN" 2>/dev/null \
        | /usr/bin/env jq -r '.cmux // false' 2>/dev/null || echo false)"
    [ -z "$CMUX_ON" ] && CMUX_ON=false
fi

# Build preamble content. Under cmux: pass through. Off cmux: strip
# every <!-- paperflow:cmux-only:begin -->...:end --> block inclusive.
if [ "$CMUX_ON" = "true" ]; then
    CONTENT="$(cat "$CLAUDE_MD")"
else
    CONTENT="$(/usr/bin/awk '
        /<!-- paperflow:cmux-only:begin -->/ { skip=1; next }
        /<!-- paperflow:cmux-only:end -->/   { skip=0; next }
        skip { next }
        { print }
    ' "$CLAUDE_MD")"
fi

/usr/bin/env jq -n --arg content "$CONTENT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: (
      "<system-reminder>\nSTANDING USER INSTRUCTIONS (re-injected every turn — these override default behavior, even under context pressure):\n\n"
      + $content
      + "\n</system-reminder>"
    )
  }
}'
