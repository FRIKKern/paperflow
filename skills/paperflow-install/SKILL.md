---
name: paperflow-install
description: paperflow's meta-skill. Use when the user says "install paperflow", "upgrade paperflow", "reset paperflow", "write a new skill", "write the changelog", "what is paperflow?", or asks any meta question about the system. Bootstraps Beads (paperflow's working memory), runs the bundled `install.sh` with optional `--with-*` integration flags chosen via Q&A, can author a new SKILL.md (subject to the 6-skill cap CI gate), and writes a changelog HTML at `~/docs/paperflow/changelog/<date>-<topic>-changelog.html`. The entry-point document — points first-time users at `paperflow-goal` to start their first Goal.
---

# paperflow-install

The meta-skill — covers install/upgrade/reset, integration opt-in, skill authoring, and changelog publishing. Also serves as paperflow's "what is this?" entry point.

## What paperflow is

paperflow is one Claude Code instance running as orchestrator. It creates Goals, designs the task graph, dispatches subagents, claims Tasks in Beads while subagents run, closes Tasks on verification, routes browser button clicks back via the bridge. Beads (`bd`) is the system of record. Six skills, all `paperflow-*` prefixed, hit the cap exactly:

| Skill | What it does |
|---|---|
| `paperflow-goal` | Open / refresh / archive a Goal. Auto-creates 3 default phases. |
| `paperflow-plan` | Draft → grill → revise. Materialise plan steps as Beads work-tasks. |
| `paperflow-build` | Claim → dispatch → verify → close. Loop the active phase. |
| `paperflow-review` | Open a review-task; run review or site audit. |
| `paperflow-install` | This skill. Install / upgrade / reset / new skill / changelog. |
| `paperflow-resume` | List Goals, pick, flip pointers, open Goal HTML. |

## Process

The skill has four sub-flows. Pick by trigger.

### Sub-flow A — Install / upgrade / reset (Q&A driven)

1. **First-time detection.** Read `~/.paperflow/.major-version`.
   - **Missing** → fresh install. Walk the user through the three integration questions below.
   - **Present** → ask: "fresh install with new flags, upgrade in place (re-run as is), or reset (back up and wipe)?" Default to upgrade in place.

2. **The three integration questions** — ask one at a time, capture y/N. The default is N for each — paperflow ships with everything that doesn't have an external dependency by default; these flags only gate things that pollute `~/.claude/CLAUDE.md` if the user doesn't actually use them.

   1. "Do you have OpenClaw installed (`/opt/homebrew/bin/openclaw`)? It's a local LLM agent for GUI automation. (y/N)"
   2. "Will you use BrowserBase for cloud cross-browser captures? Requires an API key from browserbase.com. (y/N)"
   3. "Want site-audit support via Unlighthouse? Installs `@unlighthouse/cli` + `puppeteer` globally via npm (~50 MB). (y/N)"

3. **Compose the install command** from the answers, then run it:

   ```bash
   bash ~/Documents/GitHub/paperflow/install.sh \
     [--with-openclaw] [--with-browserbase] [--with-unlighthouse]
   ```

   Idempotent. Without flags, `~/.claude/CLAUDE.md` stays lean — only the core paperflow doc, no integration prose appended.

4. **Read the final Status block** — components shown ✓ / ✗. Report any red lines verbatim.

5. **If the user is in an existing Claude Code session**, remind: open `/hooks` once or restart, otherwise the new hooks are inert this session.

**Reset path (destructive).** When the user says "reset paperflow", "start over", or "wipe and reinstall":

```bash
bash ~/Documents/GitHub/paperflow/install.sh --reset \
  [--with-openclaw] [--with-browserbase] [--with-unlighthouse]
```

Tarballs `~/.claude/{CLAUDE.md, hooks, skills}` and `~/.paperflow/` (excluding `~/.paperflow/backups/`) to `~/.paperflow/backups/<YYYY-MM-DD-HHMMSS>.tar.gz`, then deletes those paths and re-installs fresh with whichever `--with-*` flags were passed. Warn the user: "this will overwrite your live `~/.claude/CLAUDE.md` — backup at `~/.paperflow/backups/<ts>.tar.gz`. Untar to `/` to restore." Confirm before running.

Beads bootstrap (`bd init`) is deferred to first `paperflow-goal` in a repo.

### Sub-flow B — Write a new skill

**The cap is hit at 6.** Any new skill PR must remove or merge an existing skill in the same patch — `scripts/check-skill-count.sh` will fail otherwise. Confirm with the user which existing skill the new one displaces before writing.

1. **Spawn a subagent** to draft the SKILL.md. Brief: one-sentence purpose, ≥1 Beads command in body, ≥1 verifiable artifact named, frontmatter `description` with trigger phrases, 60–150 lines.
2. **Confirm the displacement.** Edit `install.sh` skill loop + status block to swap displaced skill for the new one.
3. **Run `bash install.sh`** then verify: `find skills -name '*.md' -type f | wc -l` returns exactly 6.
4. **Open a PR** referencing the displacement.

### Sub-flow C — Write a changelog (paperflow-itself releases only)

**Boundary:** `paperflow-review` writes changelogs for build/review work in user repos. `paperflow-install` writes changelogs for paperflow's *own* releases — installer changes, new fragments, skill displacements, hook changes. If unsure which, ask: "is this a paperflow release or a user-repo build?"

1. **Identify the topic.** A merged paperflow PR, an installer change, a new fragment.
2. **Spawn a subagent** to draft the changelog HTML. Brief: article-style HTML, files-touched table, verified-by section, one-line rollback.
3. **Write to** `~/docs/paperflow/changelog/<YYYY-MM-DD>-<topic>-changelog.html` using `/paperflow/_lib/doc.{css,js}` and the `paperflow-target` JSON.

## Artifact

- Sub-flow A: refreshed `~/.claude/CLAUDE.md` (lean core + opted-in fragments), hooks, LaunchAgents, renderers, statusline. `~/.paperflow/.major-version` set to 2.
- Sub-flow A (`--reset`): backup tarball at `~/.paperflow/backups/<ts>.tar.gz`, fresh install on top.
- Sub-flow B: a new `skills/<name>/SKILL.md` (with the 6-skill cap satisfied via displacement), updated `install.sh`.
- Sub-flow C: a changelog HTML at `~/docs/paperflow/changelog/<date>-<topic>-changelog.html`.

## Beads commands

| Verb | Purpose |
|---|---|
| `bd --version` | Pre-flight check. |
| `bd init` | Bootstrap a repo's Beads store (deferred to first `paperflow-goal`). |

This skill issues no other Beads writes — it's the meta layer.

## Verify

```bash
curl -s http://127.0.0.1:8765/                 # live-server
curl -s http://127.0.0.1:8766/                 # claude-bridge
find skills -name '*.md' -type f | wc -l       # must return 6
bash scripts/check-skill-count.sh              # CI gate, must return ✓
```

## Don't

- Don't ship a 7th skill without removing one. The cap is real.
- Don't overwrite `~/.claude/CLAUDE.md` on a normal install — only `--reset` overwrites (after backing up).
- Don't auto-install Unlighthouse / BrowserBase deps without asking.
- Don't append integration fragments the user didn't opt into.
- Don't write a changelog before the work has shipped.
