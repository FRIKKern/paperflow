---
name: mission-continue
description: Use when the user says "continue this mission in a new tab", "spawn fresh Claude with this context", "open this mission in a fresh session", or clicks the Continue button on a mission HTML. Runs mission-snapshot to refresh state, then invokes the paperflow-continue launcher to spawn a new terminal tab running `claude --dangerously-skip-permissions <resume_prompt>` for the active mission.
---

# mission-continue

Spawn a fresh Claude Code session in a new terminal tab, pre-loaded with the mission's resume prompt. Used when the current session's context is filling up or when the user wants to hand off to a clean slate.

## When to fire

| Use this skill when | Skip when |
|---|---|
| User says "continue this mission in a new tab" | No active mission |
| User clicks Continue on the mission HTML | Single one-off task |
| Context window is filling and a fresh start is imminent | User wants to keep working in this session |

## Process

1. **Run `mission-snapshot` first.** This refreshes the JSON sidecar with current artifacts, progress, and a fresh `resume_prompt` — so the new tab starts with the latest state, not stale-from-creation state. If snapshot returns "No active mission", stop and tell the user.

2. **Read the active slug:**
   ```bash
   SLUG="$(cat ~/.paperflow/active-mission)"
   ```

3. **Invoke the launcher:**
   ```bash
   ~/.local/bin/paperflow-continue "$SLUG"
   ```

   The launcher detects the current terminal (tmux / iTerm / Apple Terminal / fallback) and opens a new tab/window running:
   ```
   cd ~ && claude --dangerously-skip-permissions <resume_prompt>
   ```

4. **Reply** with one short sentence: which terminal path the launcher used + which slug, e.g. "Opened a new iTerm tab for `2026-05-02-paperflow-v2` — the fresh session will read the mission HTML and pick up at `<next-step>`."

   If the launcher errored, surface the error and the path it tried.

## How the resume_prompt is shaped

Set by `mission-create` at creation and refreshed by `mission-snapshot`:

```
You are continuing the <name> mission. Read /Users/<user>/docs/paperflow/missions/<slug>.html in full. Then do: <next-step>.
```

The fresh Claude session reads the mission HTML (which mirrors the JSON), gets the full picture (vision, artifacts, decisions, open questions), and starts work on the concrete next-step.

## Don't

- Don't skip the snapshot step — a stale resume_prompt makes the new tab pick up at the wrong place.
- Don't try to support kitty / WezTerm / Ghostty — phase 2.
- Don't try to keystroke into the new tab from the current session. The launcher passes the prompt as a CLI arg to `claude`, which is more reliable than `write text` or `send-keys` of the prompt body.
- Don't fall back silently if the launcher fails — surface the error so the user knows nothing happened.
