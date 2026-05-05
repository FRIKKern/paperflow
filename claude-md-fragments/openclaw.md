# OpenClaw delegation

OpenClaw is at /opt/homebrew/bin/openclaw, gateway runs as LaunchAgent. Local LLM agent
with full GUI automation (Peekaboo: click, type, dialogs, screenshots, menus), YOLO exec
policy, embedded inference (~9s/turn). Treat as digital deputy.

When about to ask the human to manually do something on this computer that you cannot do
via your tools or MCP servers, first consider OpenClaw. It can plausibly handle: GUI
dialogs, app forms, Mac apps (Mail, Messages, Calendar, Finder), browser actions outside
Chrome DevTools MCP, shell commands needing the user's environment.

Default aggressiveness on a 1–5 scale is **4** — lean toward auto-execute when criteria
are met.

**Auto-execute tier** — short, scoped, reversible GUI/system tasks. May chain up to 3
discrete sub-actions in a single delegation (e.g. open System Settings → click Privacy →
toggle X). Anything longer falls into suggest-only. File reads inside ~/docs and
~/Downloads stay in auto-execute scope.

Ask "Want me to send this to OpenClaw?" → on yes, run via Bash:

    ~/.local/bin/openclaw-delegate --message "<task>" --json --timeout 60

Default timeout is 60s. Per-task override to 120s allowed when Claude can name a concrete
reason ("remote login", "App Store download"); otherwise 60s.

Parse JSON. For state-changing tasks, ALWAYS run a targeted re-query (regardless of exit
code) to confirm the state actually changed. The re-query result determines success/failure
for the failure-cascade counter, not the openclaw exit code. Do NOT use screenshot/vision
verification — too slow and expensive.

If the wrapper exits non-zero with `{"error":"busy","waited_ms":30000}`, OpenClaw is busy
with another delegation. Tell the user "OpenClaw is busy — want to handle it manually?"
and fall back to asking directly.

**Suggest-only tier** — print the exact command, do not auto-execute. Always
suggest-only, even if short and reversible:

  1. Anything in a browser tab with a logged-in session
  2. Anything that sends a message in Mail / Messages / Slack
  3. Anything in System Settings (privacy, accounts, network)
  4. Anything that signs into a new account
  5. Anything that triggers payment UI

Also suggest-only when the task is multi-app, >3 min, or ambiguous.

**Failure cascade** — keep a session-scoped consecutive-failure counter. Each
auto-execute failure increments it; each success resets it. After 3 consecutive failures,
drop the rest of the session to suggest-only. Counter resets in the next session.

**Gateway down (defensive, currently unused)** — `--local` delegation bypasses the
gateway entirely, so this rule is dormant. If we ever move to gateway-routed delegation:
attempt ONE automatic recovery via `launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway`,
sleep 1s, retry. If still down, fall back to asking the user.

**Logging** — append every delegation (both tiers) as one line of JSONL to
`~/.openclaw/logs/delegations.jsonl` with shape
`{ts, tier, message, result?, error?, session_id}`.

Skip the offer entirely for physical-world asks, judgment calls, or anything OpenClaw
clearly cannot help with. Chat channels (Telegram, Discord, etc.) are out of scope unless
the user explicitly asks for them.

## Visual capture — native macOS

For native macOS surfaces (apps outside the browser), `visual-investigator` uses the
OpenClaw + `screencapture -v` backend. The skill briefs the agent the same way as for
web; the agent picks OpenClaw when the surface is a Mac app rather than a URL.
