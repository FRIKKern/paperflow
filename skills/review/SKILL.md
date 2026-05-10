---
name: review
description: Use when the user says "request review", "receive review on PR #N", "finish this branch", "audit the site", or wants to verify, test, or hand off a build-task. Opens a review-task in Beads linked to its parent build-task and to the review phase-task; delegates the review to a subagent. Closes the review-task on approval; re-opens the parent build-task on rejection. Site audits live here too — `paperflow-audit-site` runs through the same review-task wrapper.
---

# review

Request + receive code review, finish a development branch, run a site audit. Lives naturally in the `review` phase. The orchestrator opens a review-task linked to a build-task; the subagent runs the review (or audit); the result determines whether the parent build-task stays closed or re-opens.

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


## Step 0.5 — Doc metadata (mandatory)

Before writing any HTML doc, call:

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


## When to fire

| Use this skill when | Skip when |
|---|---|
| "request review on this branch" | No build-task to review yet |
| "receive review on PR #N" | The review came back with no issues — close inline, no skill needed |
| "finish this branch" / "merge it" | The branch isn't ready — verify-first via `/paperflow:build` |
| "audit the site" / "run lighthouse" | A site that isn't live or doesn't have URLs to crawl |

## Process

_Section structure adapted from `obra/superpowers/skills/requesting-code-review`, `receiving-code-review`, and `finishing-a-development-branch` (MIT) — see `THIRD-PARTY-CREDITS.md`._

The orchestrator wraps every review activity in a Beads review-task so the audit trail captures the verdict. The review-task depends on the build-task it covers and on the `review` phase-task of the active goal.

### Opening a review

1. **Identify the build-task being reviewed.** Either the user names it explicitly, or the orchestrator finds the most recent closed work-task in the active goal.

2. **Create the review-task:**

   ```bash
   bd create "Review: <branch or PR>" --label goal-<slug>
   bd dep add <review-task> <build-task>
   bd dep add <review-task> <review-phase-task>
   ```

3. **Dispatch a subagent.** Subagent default: `paperflow-researcher` (read-only — cannot accidentally fix while reviewing). Fall back to `general-purpose` only when the task crosses categories. Brief: the diff (`git diff main...HEAD`), the build-task description, the verification evidence captured at build-close, and the criteria for approval. The subagent reviews and returns `{ verdict: approved | rejected, notes: [...] }`.

### Closing on approval

```bash
bd update <review-task> --close
```

If the user wants the branch merged + cleaned up, follow with:

```bash
git checkout main && git pull
git merge --no-ff <branch>
git branch -d <branch>
```

### Re-opening on rejection

```bash
bd update <build-task> --reopen
bd update <review-task> --close   # the review itself is done; the work isn't
```

`/paperflow:build` will pick the re-opened build-task up via `bd ready` on the next iteration.

### Subagent-Run audit

Every review-task includes a run of `~/.local/bin/paperflow-audit-orchestrator-budget` against the build-phase commits being reviewed. The audit script flags any commit whose net LOC change exceeds 30 and lacks at least one `Subagent-Run: <task-id>` trailer in the commit message body.

```bash
~/.local/bin/paperflow-audit-orchestrator-budget --since main
```

For each flagged commit, the review subagent must either:

1. **Justify it** — add a one-paragraph note to the review-task explaining why the threshold was exceeded inline (e.g. the orchestrator's pre-write checkpoint line is in the transcript, the work was a single coherent edit that fragmented poorly), OR
2. **Reopen the build-task** — `bd update <build-task> --reopen` and brief the next builder to retry with proper subagent dispatch + the trailer convention.

The audit is informational (`exit 0` always). The discipline lives in the review judgement: a flagged commit without a justification fails the review.

### Site audit sub-flow

The site audit reuses the review-task wrapper:

1. Open a review-task labelled `audit-<site>` linked to the goal.
2. Spawn a subagent that runs `~/.local/bin/paperflow-audit-site --site <url>` and surfaces the `<dir>/index.html` report.
3. The subagent returns the report URL + a one-line verdict (e.g. "lighthouse perf=82 a11y=96, no blockers").
4. Close the review-task on a clean audit; surface the report URL otherwise.

The audit HTML is the verifiable artifact even when the verdict is "needs work".

### Changelog HTML

When a review approves a build that ships UI work, the changelog HTML lands at `~/docs/paperflow/changelog/<date>-<topic>-changelog.html`. **Every paperflow HTML you write MUST include** `<script>window.PAPERFLOW_GOAL_ID = "<goal-id>";</script>` near the existing `window.DOC_PATH` block. The goal-path rail reads this to know which Goal's events to show; without it the rail can't anchor the changelog into the Goal's path.

## Artifact

- A review-task in Beads linked to the build-task and to the review phase-task. Closed on approval; closed (with build-task re-opened) on rejection.
- A PR thread / merged branch / audit HTML at `~/docs/paperflow/audits/<slug>/index.html`, depending on flow.
- `~/.paperflow/statusline.txt` refreshed.

## Beads commands

| Verb | Purpose |
|---|---|
| `bd create "Review: <branch>" --label goal-<slug>` | Open the review-task. |
| `bd dep add <review> <build>` | Link to the build-task being reviewed. |
| `bd dep add <review> <review-phase-task>` | Attach to the review phase. |
| `bd update <review> --close` | Close on approval (or after rejection-with-reopen). |
| `bd update <build> --reopen` | Re-open the parent build-task on rejection. |

## Don't

- Don't approve without a review-task. The audit trail matters — closed-without-record reviews disappear.
- Don't merge a branch with a still-open review-task. The verdict gates the merge.
- Don't re-open the build-task without leaving rejection notes. The next builder needs to know what failed.
- Don't run a site audit without wrapping in a review-task. Audits are review activity; they belong in the trail.
