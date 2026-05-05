---
name: paperflow-install
description: paperflow's meta-skill. Use when the user says "install paperflow", "upgrade paperflow", "write a new skill", "write the changelog", "what is paperflow?", or asks any meta question about the system. Bootstraps Beads (paperflow's working memory), runs the bundled `install.sh`, can author a new SKILL.md (subject to the 6-skill cap CI gate), and writes a changelog HTML at `~/docs/paperflow/changelog/<date>-<topic>-changelog.html`. The entry-point document — points first-time users at `paperflow-goal` to start their first Goal.
---

# paperflow-install

The meta-skill — covers install/upgrade, skill authoring, and changelog publishing. Also serves as paperflow's "what is this?" entry point.

## What paperflow is

paperflow is one Claude Code instance running as orchestrator. It creates Goals, designs the task graph, dispatches subagents to do focused work, claims Tasks in Beads while subagents run, closes Tasks on verification, and routes browser button clicks back into its own session via the bridge. Beads (`bd`) is the system of record; `<repo>/.beads/` is the per-repo store. Six skills, all `paperflow-*` prefixed, hit the cap exactly:

| Skill | What it does |
|---|---|
| `paperflow-goal` | Open / refresh / archive a Goal. Auto-creates 3 default phases. |
| `paperflow-plan` | Draft → grill → revise. Materialise plan steps as Beads work-tasks. |
| `paperflow-build` | Claim → dispatch → verify → close. Loop through the active phase, advance phases. |
| `paperflow-review` | Open a review-task; run review or site audit; close on approval, re-open build-task on rejection. |
| `paperflow-install` | This skill. Install / upgrade / write a new skill / write a changelog. |
| `paperflow-resume` | List Goals, pick one, flip pointers, open Goal HTML. |

Read the spec at `~/docs/paperflow/specs/2026-05-04-paperflow-owns-its-surface.html` for the long form.

## When to fire

| Use this skill when | Skip when |
|---|---|
| "install paperflow" / "upgrade paperflow" | A specific component is broken — fix it directly |
| "the bridge isn't running" / "live reload broke" | The user is asking a question about paperflow's behaviour — answer inline |
| "write a new skill called X" | An existing skill covers it — reuse |
| "write the changelog for this release" | The work is mid-flight — `paperflow-build` is still iterating |
| "what is paperflow?" / first-time user | The user is mid-Goal — let `paperflow-resume` handle context |

## Process

The skill has three sub-flows. Pick one based on the trigger.

### Sub-flow A — Install / upgrade

_Section structure adapted from `obra/superpowers/skills/using-superpowers` (MIT) — see `THIRD-PARTY-CREDITS.md`._

1. **Check Beads is on PATH.** `command -v bd >/dev/null` or fail with the install command (`brew install beads` or `npm i -g beads`).
2. **Check the repo is cloned.** Default location: `~/Documents/GitHub/paperflow/`. If absent, clone via `gh` SSH or HTTPS fallback.
3. **Run the installer:**

   ```bash
   bash ~/Documents/GitHub/paperflow/install.sh
   ```

   Idempotent. Detects already-installed pieces, refreshes plists, kickstarts running LaunchAgents.
4. **Read the final Status block** — components as ✓ / ✗. Report any red lines verbatim.
5. **Bootstrap Beads in the active repo if missing:** `bd init` is run lazily by `paperflow-goal` on first goal creation. The installer doesn't touch repo-level Beads stores.
6. **If the user is in an existing Claude Code session**, remind them: open `/hooks` once or restart, otherwise the new hooks are inert this session.

Pre-flight: if `install.sh` fails with "Node v22+ not found", point the user at `brew install node` or `nvm install 22`.

### Sub-flow B — Write a new skill

_Section structure adapted from `obra/superpowers/skills/writing-skills` (MIT) — see `THIRD-PARTY-CREDITS.md`._

**The cap is hit at 6.** Any new skill PR must remove or merge an existing skill in the same patch — CI will fail otherwise. Confirm with the user which existing skill the new one displaces before doing any writing.

1. **Spawn a subagent** to draft the SKILL.md. Brief: the spec's quality bar (one-sentence purpose, ≥1 Beads command in body, ≥1 verifiable artifact named, frontmatter `description` with trigger phrases), 60–150 lines, the section shape (Process / Artifact / Beads commands / Don't), and the new skill's purpose.
2. **Confirm the displacement.** Edit `install.sh` skill loop + status block to swap the displaced skill for the new one. Edit the CI cap script if needed.
3. **Run `bash install.sh`** to verify the change, then `find skills -name '*.md' -type f | wc -l` returns exactly 6.
4. **Open a PR** referencing the displacement.

### Sub-flow C — Write a changelog

1. **Identify the topic.** A merged PR, a shipped feature, a closed Goal.
2. **Spawn a subagent** to draft the changelog. Brief: article-style HTML, before/after captures if available (read `~/docs/paperflow/captures/<slug>/`), files-touched table, verified-by section, one-line rollback.
3. **Write the HTML** to:

   ```
   ~/docs/paperflow/changelog/<YYYY-MM-DD>-<topic>-changelog.html
   ```

   Use `/paperflow/_lib/doc.{css,js}` and embed the `paperflow-target` JSON.

## Artifact

- Sub-flow A: refreshed `~/.claude/CLAUDE.md`, hooks, LaunchAgents, renderers, statusline. `~/.paperflow/.major-version` ticked when crossing a boundary.
- Sub-flow B: a new `skills/<name>/SKILL.md` (with the 6-skill cap satisfied via displacement), updated `install.sh`.
- Sub-flow C: a changelog HTML at `~/docs/paperflow/changelog/<date>-<topic>-changelog.html`.

## Beads commands

| Verb | Purpose |
|---|---|
| `bd --version` | Pre-flight check. |
| `bd init` | Bootstrap a repo's Beads store (deferred to first `paperflow-goal`). |

This skill issues no other Beads writes — it's the meta layer, not the operating layer.

## Verify

```bash
curl -s http://127.0.0.1:8765/                 # live-server (HTML directory)
curl -s http://127.0.0.1:8766/                 # claude-bridge → "claude-bridge ok"
find skills -name '*.md' -type f | wc -l       # must return 6
```

## Don't

- Don't ship a 7th skill without removing one. The cap is real now, not theoretical.
- Don't write `CLAUDE.md` if it already exists. The user's edits live there.
- Don't re-clone the repo if it exists — `git pull` instead, then `install.sh`.
- Don't write a changelog before the work has shipped. Write the proof, not the promise.
