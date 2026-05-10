---
name: setup
description: Use FIRST after `/plugin install paperflow`. Lays down host-side install (LaunchAgents, cmux dock, statusline, CLAUDE.md, ~/.local/bin shims, brew installs `bd`). Asks for consent, runs `install.sh`, reports status. Re-run with `--reset` or `--upgrade` later. Back-compat trigger: also fires on "bootstrap".
---

# setup

paperflow ships as a Claude Code plugin (skills + hooks + slash commands), but it ALSO needs host-side infrastructure to deliver its full experience: LaunchAgents serving HTML docs on port 8765, the claude-bridge HTTP server on 8766 routing button clicks back to the terminal, the cmux dock daemon, the statusline, and a host-wide `bd` binary for the dock daemon's LaunchAgent context. None of those can be installed by the plugin alone.

This skill runs the existing `install.sh` with the user's explicit consent.

<!-- Step 0.5 (paperflow-doc-meta) is exempt here — `/paperflow:setup` is a one-shot host installer; it does not write doc HTMLs. -->

## Process

1. **Locate plugin root.** First try `$CLAUDE_PLUGIN_ROOT`. If unset, discover via:

   ```bash
   find ~/.claude/plugins/cache -maxdepth 4 -type d -name 'paperflow' | head -1
   ```

2. **Check sentinel.** If `~/.paperflow/installed` exists, this is a re-run. Offer the user `--reset`, `--upgrade`, or "skip — already installed".

3. **Explain what will happen.** Print a plain-language summary of what `install.sh` does (LaunchAgents on ports 8765 + 8766, dock daemon at ~/.paperflow/dock.sock, statusline, ~/.claude/CLAUDE.md write, ~/.local/bin/ symlinks, optional brew installs).

4. **Ask consent.** Use `AskUserQuestion` with the choices: "Run setup", "Show me what install.sh does first (cat the file)", "Cancel".

5. **Run.** `bash "$PLUGIN_ROOT/install.sh"`. Stream progress; surface errors.

6. **Verify.** After install.sh exits 0, run `~/.local/bin/paperflow-doctor --fast`. Report the issues array if any.

7. **Done.** Tell the user the next step: `/paperflow:goal "your first goal"`. Or for momentum: `/paperflow:autopilot "your vision"` to chain everything in one push (pauses at grill).

## Re-run modes

- No flag: skip if sentinel present, else run as fresh install.
- `--upgrade`: re-run install.sh (idempotent), pick up new helpers / renderers / hooks.
- `--reset`: prompt for confirmation, then `bash "$PLUGIN_ROOT/uninstall.sh"` first, then re-run setup.

## Sentinel

Write `~/.paperflow/installed` on successful first run. Contains the plugin version + ISO timestamp.
