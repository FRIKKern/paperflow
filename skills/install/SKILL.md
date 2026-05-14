---
name: install
description: paperflow's meta-skill. Use when the user says "install paperflow", "upgrade paperflow", "reset paperflow", "write a new skill", "write the changelog", "what is paperflow?", or asks any meta question about the system. Bootstraps Beads (paperflow's working memory), runs the bundled `install.sh` with optional `--with-*` integration flags chosen via Q&A, can author a new SKILL.md (subject to the 8-skill cap CI gate), and writes a changelog HTML at `~/docs/paperflow/changelog/<date>-<topic>-changelog.html`. The entry-point document — points first-time users at `/paperflow:goal` to start their first Goal.
---

# install

The meta-skill — covers install/upgrade/reset, integration opt-in, skill authoring, and changelog publishing. Also serves as paperflow's "what is this?" entry point.

**install vs setup.** Two different verbs, two different jobs.
`/paperflow:setup` is the **first-run** host installer — runs `install.sh` after `/plugin install paperflow`, idempotent re-runs handle `--upgrade` / `--reset`. Trigger phrases are literal: "/paperflow:setup", "set up paperflow", "bootstrap paperflow" (back-compat). It's a thin wrapper around `bash install.sh`.
`/paperflow:install` is the **meta-skill** — write a new SKILL.md (within the 8-skill cap), publish a paperflow release changelog, answer "what is paperflow?". It also drives Q&A install/upgrade/reset flows when the user wants integration flag selection (`--with-openclaw`, `--with-browserbase`, `--with-unlighthouse`) — the setup skill is the bare consent path; the install skill is the guided path.

<!-- BEGIN paperflow-thresholds -->
## Subagent enforcement (paperflow-thresholds v1)

paperflow's orchestrator delegates non-trivial work to subagents. The rule has hard thresholds and a pre-write checkpoint — not just guidance.

**Hard thresholds** — above ANY of these, the orchestrator MUST dispatch a subagent:

- **> 30 LOC** of new code (across all files in one logical unit)
- **> 50 lines** of new prose / markdown
- **> 500 tokens** of raw tool output captured / synthesised

**Bash-glue carve-out**: bash glue scripts ≤ **25 LOC** stay inline. Other languages (JS, Python, etc.) hold the 30 LOC gate.

**Pre-write checkpoint**: before any inline `Write` or `Edit` of more than 30 LOC of code OR 50 lines of prose, the orchestrator prints a one-line justification:

    Doing inline because: <reason>. Above threshold would be <subagent-reason>.

Visible self-correction, not silent inlining.

**Recursion depth = 1**: subagent briefs themselves are orchestrator-direct, no matter their length. The orchestrator can write a 600-token brief without dispatching to write the brief — otherwise infinite recursion.

**Verification-subagent dispatch**: when a subagent returns artifacts > 500 tokens of evidence (diffs, test output, screenshots), `/paperflow:build` dispatches a SECOND subagent — a verification-subagent — to inspect the evidence and confirm the gate passes. The orchestrator only sees a one-line verdict.

**Commit-message marker**: any commit touching > 30 LOC includes a structured trailer:

    Subagent-Run: <task-id>

`bin/paperflow-audit-orchestrator-budget` flags over-threshold commits that lack this trailer.

**Always orchestrator-direct (exempt list)** — never dispatch a subagent for:

- Beads bookkeeping (`bd create / claim / close / update --description`)
- Pointer-file writes (`<repo>/.paperflow/active-{goal,phase}`)
- `Read` (always free)
- Short verification commands (`curl` probes, `find … | wc -l`, single-shot greps)
- Single-line edits to live docs to bump pointers / status
- Snapshot writes that change ≤ 5 lines of an existing HTML
- `bd` comments and `bd update --description` (any size)
- Pasting verbatim subagent output (the subagent already did the work)
- Bash glue scripts ≤ 25 LOC (carve-out above)

When in doubt, dispatch.
<!-- END paperflow-thresholds -->

<!-- BEGIN paperflow-step-0 -->
## Step 0 — Runtime preflight + doctor

Before doing anything else, validate that the message-carrying runtime is up and the install is healthy.

**1. Runtime probe.**

    ~/.local/bin/paperflow-preflight

Non-zero → abort the skill and paste the JSON from stdout to the user verbatim. The JSON carries `service`, `mode` (`cmux` or `launchagent`), `repair_command`, and `log_tail` — the user runs the repair, then re-invokes the skill.

**2. Doctor (deps + version + integrity).**

    ~/.local/bin/paperflow-doctor --fast

Read the JSON from stdout and react by exit code:

| Exit | Meaning | Action |
|---|---|---|
| 0 | Clean | Continue silent. |
| 1 | Warnings (outdated, optional dep missing, drift already auto-fixed) | Continue. Print a one-line summary at the start of the skill's main work: `Doctor: N warning(s) — run paperflow-doctor --full to inspect.` |
| 2 | Critical (bd/node missing, settings.json corrupted) | Abort. For each issue with `auto_fix_safe:false`, surface the `repair_command` and ask the user with `AskUserQuestion` whether to run it. |
<!-- END paperflow-step-0 -->


## Step 0.5 — Doc metadata (mandatory)

The changelog HTMLs this skill writes go through the same metadata helper as every other paperflow doc. Before writing the changelog, call:

    ~/.local/bin/paperflow-doc-meta

Parse the JSON. Embed `time_display`, `device`, and `cmux_workspace` (if non-null) into the doc's `<div class="byline">` as additional `<span>` elements alongside the existing date / topic / status spans. The byline should now read:

    <div class="byline">
      <span>2026-05-10 · 17:42 CEST</span>     <!-- date + time_display from helper -->
      <span>Topic / category</span>
      <span>One-phrase status or conclusion</span>
      <span>Mac · cmux-workspace-3</span>      <!-- device · cmux_workspace from helper -->
    </div>

Embed `active_goal_id` into the required script tail:

    <script>
      window.CLAUDE_TARGET = { ... };
      window.DOC_PATH = "<this-filename>.html";
      window.PAPERFLOW_GOAL_ID = "<active_goal_id from helper>";
    </script>

If the helper auto-created a session Goal (`auto_created: true` in the JSON), surface that to the user in the chat reply: "Auto-created session Goal `<title>` for this doc — rename it whenever via `bd update <id> --title …`."

Never invent or guess these values — always shell out to the helper.


## Dock trust prompt

`bash install.sh` now writes a personal `${XDG_CONFIG_HOME:-$HOME/.config}/cmux/dock.json` with paperflow's four feeds (active-context · bd-ready · goal-path · auto-open-log) and spawns the long-running daemon at `~/.paperflow/dock.sock`. cmux has no `trust` subcommand or per-config trust verb (verified at build time via `cmux --help` and `cmux help` — no match for "trust" or "dock"). Personal-scope dock configs at `~/.config/cmux/` load without a per-repo prompt; commands run inside the user's normal login shell.

If a future cmux release prompts on first dock load (per-repo `.cmux/dock.json` is the case the cmux team has reserved this for), accept the prompt — paperflow's dock.json contains only paperflow-managed `watch -n 5 paperflow-dock-feed <name>` entries that talk to the local daemon. Nothing in the dock invokes a remote.

## Refreshing the threshold block

`lib/shared-thresholds.md` in the paperflow repo is the single source of truth for the block above. On every `bash install.sh` run, the **Refresh threshold blocks** step regenerates the content between `<!-- BEGIN paperflow-thresholds -->` and `<!-- END paperflow-thresholds -->` in each non-exempt skill body — `/paperflow:{goal,plan,build,review,install}`. `/paperflow:resume` is exempt (read-only on Beads, never authors prose against the threshold).

Skills carry the prose locally so Claude Code's skill loader can read it directly (no transitive include); the file is the source of truth; the install reconciles them. Editing the block in any one skill body is fine for a quick local trial, but the next install will overwrite from `lib/shared-thresholds.md`. Edits that should stick go into `lib/shared-thresholds.md` first.

## What paperflow is

paperflow is one Claude Code instance running as orchestrator. It creates Goals, designs the task graph, dispatches subagents, claims Tasks in Beads while subagents run, closes Tasks on verification, routes browser button clicks back via the bridge. Beads (`bd`) is the system of record. Eight skills, all `/paperflow:*` namespaced, hit the cap exactly:

| Skill | What it does |
|---|---|
| `/paperflow:goal` | Open / refresh / archive a Goal. Auto-creates 3 default phases. |
| `/paperflow:plan` | Draft → grill → revise. Materialise plan steps as Beads work-tasks. |
| `/paperflow:build` | Claim → dispatch → verify → close. Loop the active phase. |
| `/paperflow:review` | Open a review-task; run review or site audit. |
| `/paperflow:install` | This skill. Install / upgrade / reset / new skill / changelog. |
| `/paperflow:resume` | List Goals, pick, flip pointers, open Goal HTML. |
| `/paperflow:setup` | First-run host install — runs `install.sh` after `/plugin install paperflow`. |
| `/paperflow:autopilot` | Chains `goal → plan → grill → build → review` in one push. Pauses at the grill. |

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

Beads bootstrap (`bd init`) is deferred to first `/paperflow:goal` in a repo, which calls `paperflow-doctor --ensure-bd` (the legacy `paperflow-bd-init` binary has been folded into doctor).

### Sub-flow B — Write a new skill

**The cap is hit at 8** (the six lifecycle skills, the plugin `setup` skill, and the `autopilot` skill). Any new skill PR must remove or merge an existing skill in the same patch — `scripts/check-skill-count.sh` will fail otherwise. Confirm with the user which existing skill the new one displaces before writing.

1. **Spawn a subagent** to draft the SKILL.md. Subagent default for the install skill stays `general-purpose` — this meta-skill spans research + writing + bd ceremony + bash, so the named-agent palette doesn't fit any single dispatch cleanly. Brief: one-sentence purpose, ≥1 Beads command in body, ≥1 verifiable artifact named, frontmatter `description` with trigger phrases, 60–150 lines.
2. **Confirm the displacement.** Edit `install.sh` skill loop + status block to swap displaced skill for the new one.
3. **Run `bash install.sh`** then verify: `find skills -name '*.md' -type f | wc -l` returns exactly 8.
4. **Open a PR** referencing the displacement.

### Sub-flow C — Write a changelog (paperflow-itself releases only)

**Boundary:** `/paperflow:review` writes changelogs for build/review work in user repos. `/paperflow:install` writes changelogs for paperflow's *own* releases — installer changes, new fragments, skill displacements, hook changes. If unsure which, ask: "is this a paperflow release or a user-repo build?"

1. **Identify the topic.** A merged paperflow PR, an installer change, a new fragment.
2. **Spawn a subagent** to draft the changelog HTML. Brief: article-style HTML, files-touched table, verified-by section, one-line rollback.
3. **Write to** `~/docs/paperflow/changelog/<YYYY-MM-DD>-<topic>-changelog.html` using `/paperflow/_lib/doc.{css,js}` and the JSON from `~/.local/bin/paperflow-target <changelog-html-path>` (the path argument is required — the helper registers the doc_nonce with the bridge as a side-effect; calling it without a path now aborts with `register-failed`).

## Artifact

- Sub-flow A: refreshed `~/.claude/CLAUDE.md` (lean core + opted-in fragments), hooks, LaunchAgents, renderers, statusline. `~/.paperflow/.major-version` set to 2.
- Sub-flow A (`--reset`): backup tarball at `~/.paperflow/backups/<ts>.tar.gz`, fresh install on top.
- Sub-flow B: a new `skills/<name>/SKILL.md` (with the 8-skill cap satisfied via displacement), updated `install.sh`.
- Sub-flow C: a changelog HTML at `~/docs/paperflow/changelog/<date>-<topic>-changelog.html`.

## Beads commands

| Verb | Purpose |
|---|---|
| `bd --version` | Pre-flight check. |
| `bd init` | Bootstrap a repo's Beads store (deferred to first `/paperflow:goal`). |

This skill issues no other Beads writes — it's the meta layer.

## Verify

```bash
curl -s http://127.0.0.1:8765/                 # live-server
curl -s http://127.0.0.1:8766/                 # claude-bridge
find skills -name '*.md' -type f | wc -l       # must return 8
bash scripts/check-skill-count.sh              # CI gate, must return ✓
```

## Don't

- Don't ship an 8th skill without removing one. The cap is real.
- Don't overwrite `~/.claude/CLAUDE.md` on a normal install — only `--reset` overwrites (after backing up).
- Don't auto-install Unlighthouse / BrowserBase deps without asking.
- Don't append integration fragments the user didn't opt into.
- Don't write a changelog before the work has shipped.
