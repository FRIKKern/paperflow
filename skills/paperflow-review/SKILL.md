---
name: paperflow-review
description: Use when the user says "request review", "receive review on PR #N", "finish this branch", "audit the site", or wants to verify, test, or hand off a build-task. Opens a review-task in Beads linked to its parent build-task and to the review phase-task; delegates the review to a subagent. Closes the review-task on approval; re-opens the parent build-task on rejection. Site audits live here too — `paperflow-audit-site` runs through the same review-task wrapper.
---

# paperflow-review

Request + receive code review, finish a development branch, run a site audit. Lives naturally in the `review` phase. The orchestrator opens a review-task linked to a build-task; the subagent runs the review (or audit); the result determines whether the parent build-task stays closed or re-opens.

## When to fire

| Use this skill when | Skip when |
|---|---|
| "request review on this branch" | No build-task to review yet |
| "receive review on PR #N" | The review came back with no issues — close inline, no skill needed |
| "finish this branch" / "merge it" | The branch isn't ready — verify-first via `paperflow-build` |
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

3. **Dispatch a subagent.** Brief: the diff (`git diff main...HEAD`), the build-task description, the verification evidence captured at build-close, and the criteria for approval. The subagent reviews and returns `{ verdict: approved | rejected, notes: [...] }`.

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

`paperflow-build` will pick the re-opened build-task up via `bd ready` on the next iteration.

### Site audit sub-flow

The site audit reuses the review-task wrapper:

1. Open a review-task labelled `audit-<site>` linked to the goal.
2. Spawn a subagent that runs `~/.local/bin/paperflow-audit-site --site <url>` and surfaces the `<dir>/index.html` report.
3. The subagent returns the report URL + a one-line verdict (e.g. "lighthouse perf=82 a11y=96, no blockers").
4. Close the review-task on a clean audit; surface the report URL otherwise.

The audit HTML is the verifiable artifact even when the verdict is "needs work".

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
