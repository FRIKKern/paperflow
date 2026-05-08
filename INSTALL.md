# Installing paperflow

The fastest path is the one-liner in the [README](./README.md). This file covers everything underneath it.

---

## What gets installed

| Component | Path on your Mac | Purpose |
|---|---|---|
| `docs-livereload` LaunchAgent | `~/Library/LaunchAgents/dev.<user>.docs-livereload.plist` | Hot reload for `~/docs/` on port 8765 |
| `claude-bridge` LaunchAgent | `~/Library/LaunchAgents/dev.<user>.claude-bridge.plist` | Routes browser button clicks back to your terminal |
| Standing principles | `~/.claude/CLAUDE.md` | Loaded into every Claude Code session (only created if missing) |
| UserPromptSubmit hook | `~/.claude/hooks/inject-principles.sh` | Re-injects principles every turn (bloat-resistant) |
| Auto-open hook | `~/.claude/hooks/auto-open-doc.sh` | Opens any spec/plan/grill/note HTML you write |
| Doc renderer | `~/docs/paperflow/_lib/doc.{css,js}` | Auto-injects per-doc-type action buttons |
| Grill renderer | `~/docs/paperflow/_lib/grill.{css,js}` | Form rendering + submit-back for grills |
| Skills | `~/.claude/skills/{goal,plan,build,review,install,resume,bootstrap}/SKILL.md` | Claude invokes these on demand (also exposed as `/paperflow:<name>` via the plugin manifest) |
| Target helper | `~/.local/bin/paperflow-target` | Emits JSON describing your terminal so doc generators can embed it |

---

## Manual install (no quickstart)

```bash
git clone https://github.com/FRIKKern/paperflow.git ~/Documents/GitHub/paperflow
bash ~/Documents/GitHub/paperflow/install.sh
```

`install.sh` is idempotent — re-running it is safe and is how you upgrade. It overwrites the LaunchAgents, hooks, renderers, skills, and helper with the latest from the repo. It does **not** touch `~/.claude/CLAUDE.md` if it already exists.

---

## Customize the LaunchAgent label

By default, plists are labeled `dev.<your-username>.docs-livereload` and `dev.<your-username>.claude-bridge`. To change the namespace:

```bash
LABEL_PREFIX=dev.youralias bash install.sh
```

Each re-run creates plists at the new label; you may want to `bash uninstall.sh` first if you're switching prefixes.

---

## Pre-flight checks

`install.sh` runs a small pre-flight section before doing any work:

- **Node 22+** — checked first. Looked up via `~/.nvm/versions/node/v22.*` and then `command -v node`.
- **jq** — required for the `settings.json` merge.

If either is missing, the script prints the exact `brew install …` command and exits without modifying anything.

---

## Verify

```bash
curl -s http://127.0.0.1:8765/    # docs-livereload (returns directory listing)
curl -s http://127.0.0.1:8766/    # claude-bridge   (returns "claude-bridge ok")
```

In any **already-running** Claude Code session, run `/hooks` once (or restart) so the hooks are picked up. New sessions get them on startup automatically.

---

## Uninstall

```bash
bash ~/Documents/GitHub/paperflow/uninstall.sh
```

Removes the LaunchAgents, hooks, settings entries, renderers, skills, and helper. **Does not** delete `~/.claude/CLAUDE.md` (your edits) or any specs/plans/grills you've written.

To also remove the npm global `live-server`:

```bash
npm uninstall -g live-server
```
