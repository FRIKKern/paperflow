#!/usr/bin/env bash
# Emits JSON describing the current Claude Code terminal target.
# Used by spec/plan/grill HTML generators to embed the right routing
# info into the page so Build / Submit buttons reach the right tab.

set -e

# Walk up the process tree from $$ to find the ancestor `claude` process
# that has a real controlling tty (not "??"). Subshells don't inherit the
# tty in some Claude Code Bash invocation modes, so $PPID isn't reliable.
find_claude_with_tty() {
  local pid="$$"
  local tries=0
  while [ "$pid" -gt 1 ] && [ "$tries" -lt 20 ]; do
    local comm tty ppid
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
    tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ "$comm" = "claude" ] && [ -n "$tty" ] && [ "$tty" != "??" ]; then
      printf '%s\t%s\n' "$pid" "$tty"
      return 0
    fi
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$ppid" ] || break
    pid="$ppid"
    tries=$((tries + 1))
  done
  return 1
}

if RESULT="$(find_claude_with_tty)"; then
  CLAUDE_PID="${RESULT%$'\t'*}"
  CLAUDE_TTY_BASE="${RESULT#*$'\t'}"
  CLAUDE_TTY="/dev/$CLAUDE_TTY_BASE"
else
  CLAUDE_PID=""
  CLAUDE_TTY=""
fi

/usr/bin/env jq -n \
  --arg tp   "${TERM_PROGRAM:-unknown}" \
  --arg tty  "$CLAUDE_TTY" \
  --arg sid  "${TERM_SESSION_ID:-}" \
  --arg tmux "${TMUX:-}" \
  --arg pid  "$CLAUDE_PID" \
  '{
    term_program: $tp,
    tty:          (if $tty == "" then null else $tty end),
    term_session_id: $sid,
    tmux_pane:    $tmux,
    pid:          ($pid | tonumber? // null)
  }'
