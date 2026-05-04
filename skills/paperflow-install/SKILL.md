---
name: paperflow-install
description: Use when the user asks to "install paperflow", set up the doc workflow on this machine, repair a broken paperflow install, fix the bridge / live-reload / hooks, or run the doc-workflow installer for any reason. Idempotent — safe to run any time. Clones the repo from GitHub if missing, then runs the bundled install.sh and reports the green/red status table.
---

# paperflow-install

Install or repair the paperflow doc-workflow stack (live-server LaunchAgent, claude-bridge LaunchAgent, hooks, renderers, grill skill, terminal-target helper, ~/.claude/CLAUDE.md).

## When to use

- "install paperflow"
- "the bridge isn't running" / "the button does nothing" / "live reload broke"
- "set up doc workflow on this machine"
- Status check: hooks present, LaunchAgents up, renderers in `~/docs/paperflow/_lib/`
- Fresh Mac, first-time setup

Run idempotently. Safe to invoke whenever you suspect drift.

## Process

**Subagent-first.** Delegate the clone + install + status-parse to a subagent (`subagent_type: general-purpose`). Brief: "Clone https://github.com/FRIKKern/paperflow.git to ~/Documents/GitHub/paperflow if not already present. Run `bash ~/Documents/GitHub/paperflow/install.sh`. Parse the final Status block. Return only: (1) the status table verbatim, (2) any red lines that need user attention, (3) whether the user needs to run `/hooks` or restart." The main session presents that synthesis to the user.

1. **Check whether the repo is present.** Default location: `~/Documents/GitHub/paperflow/`. If absent:

   ```bash
   git clone git@github.com:FRIKKern/paperflow.git ~/Documents/GitHub/paperflow
   ```

   If `gh` SSH isn't configured, fall back to HTTPS:

   ```bash
   git clone https://github.com/FRIKKern/paperflow.git ~/Documents/GitHub/paperflow
   ```

2. **Run the installer:**

   ```bash
   bash ~/Documents/GitHub/paperflow/install.sh
   ```

   This script is fully idempotent. It detects already-installed pieces and skips them, refreshes plists, kickstarts (vs. re-bootstraps) running LaunchAgents.

3. **Read the final Status block** — it lists each component as ✓ / ✗. Report the table to the user verbatim if anything is red.

4. **If the user is in an existing Claude Code session**, remind them: open `/hooks` once or restart, otherwise the new hooks are inert in this session (settings watcher only loads at session start).

## Pre-requisite check

If `install.sh` fails with "Node v22+ not found", point the user at:

```bash
brew install nvm && nvm install 22       # preferred
# or
brew install node                          # easier, no version manager
```

Other pre-reqs (jq, Xcode CLI, Claude Code) are nearly always present on a working dev Mac. If `jq` is missing: `brew install jq`.

## What gets installed

| Component | Path |
|---|---|
| `docs-livereload` LaunchAgent | `~/Library/LaunchAgents/dev.<user>.docs-livereload.plist` (port 8765) |
| `claude-bridge` LaunchAgent | `~/Library/LaunchAgents/dev.<user>.claude-bridge.plist` (port 8766) |
| Standing principles | `~/.claude/CLAUDE.md` (only written if absent) |
| UserPromptSubmit hook | `~/.claude/hooks/inject-principles.sh` |
| PostToolUse auto-open hook | `~/.claude/hooks/auto-open-doc.sh` |
| Renderers | `~/docs/paperflow/_lib/{doc,grill}.{css,js}` |
| Grill skill | `~/.claude/skills/grill-plan/SKILL.md` |
| Target helper | `~/.local/bin/paperflow-target` |
| Doc dirs | `~/docs/paperflow/{specs,plans,grills,notes}/` |

## Verify

```bash
curl -s http://127.0.0.1:8765/    # live-server (HTML directory)
curl -s http://127.0.0.1:8766/    # claude-bridge ("claude-bridge ok")
```

## Don't

- Don't write CLAUDE.md if it already exists. The user's edits live there. The installer respects this.
- Don't re-clone the repo if it exists — `git pull` instead, then `install.sh`.
- Don't disable the user's existing hooks. The installer merges, never overwrites.
