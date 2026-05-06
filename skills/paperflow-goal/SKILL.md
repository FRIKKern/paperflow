---
name: paperflow-goal
description: Use when the user says "start a goal", "open a goal for X", "snapshot the goal", "archive the goal", "what's the active goal?", or kicks off any non-trivial multi-artifact piece of work. Creates a goal-task in Beads with `kind:goal`, auto-creates three default phase-tasks (pre-flight, build, review) underneath, sets the per-repo `.paperflow/active-goal` and `.paperflow/active-phase` pointers, and renders the Goal HTML at `~/docs/paperflow/goals/<slug>/index.html`. Snapshot and archive are sub-actions of the same skill.
---

# paperflow-goal

Open / refresh / archive a Goal. paperflow's lifecycle starts here. A Goal is a Beads task with `kind:goal`; it contains Phases (children, `kind:phase`); phases contain work-tasks (grandchildren). The orchestrator always knows which Goal is active, which Phase within it is active, and which Task is currently claimed.

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

**Verification-subagent dispatch**: when a subagent returns artifacts > 500 tokens of evidence (diffs, test output, screenshots), `paperflow-build` dispatches a SECOND subagent — a verification-subagent — to inspect the evidence and confirm the gate passes. The orchestrator only sees a one-line verdict.

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

## When to fire

| Use this skill when | Skip when |
|---|---|
| "start a goal for X" / "new goal" | Single one-off question or fix |
| Multi-artifact work spanning days or sessions | Single spec or single plan with no follow-up |
| User wants to be able to `/resume` later | Stateless throwaway exploration |
| "snapshot the goal" / "archive the goal" | A goal isn't open yet — point user at this skill first |

## Process

The orchestrator does the bookkeeping itself; no subagent dispatch is needed for the four `bd` calls. The skill body is short, the work is fast, the result is durable.

1. **Pick a slug.** Kebab-case, 2–4 words. Date-prefix it: `<YYYY-MM-DD>-<slug>` (e.g. `2026-05-04-onboarding-revamp`). Confirm with the user only if ambiguous.

2. **Pre-flight Beads.** If `<repo>/.beads/` doesn't exist, run `bd init`. Idempotent: re-running on an existing repo is a no-op.

3. **Create the goal-task:**

   ```bash
   bd create "<vision sentence>" \
       --label kind:goal \
       --label goal-<slug>
   ```

   Capture the resulting task ID (e.g. `bd-a1b2`) into `$GOAL_ID`.

4. **Create three default phase-tasks** under the goal-task. Each phase-task gets `kind:phase` and a `phase-<name>` label so scoped `bd ready` queries work later:

   ```bash
   bd create "pre-flight" --label kind:phase --label goal-<slug> --label phase-pre-flight
   bd create "build"      --label kind:phase --label goal-<slug> --label phase-build
   bd create "review"     --label kind:phase --label goal-<slug> --label phase-review
   ```

   Capture `$PHASE_PREFLIGHT`, `$PHASE_BUILD`, `$PHASE_REVIEW`.

5. **Wire the dependency edges** — phase-tasks beneath the goal-task:

   ```bash
   bd dep add $PHASE_PREFLIGHT $GOAL_ID
   bd dep add $PHASE_BUILD     $GOAL_ID
   bd dep add $PHASE_REVIEW    $GOAL_ID
   ```

6. **Write the per-repo pointers** (single-line files):

   ```bash
   echo "$GOAL_ID"        > <repo>/.paperflow/active-goal
   echo "$PHASE_PREFLIGHT" > <repo>/.paperflow/active-phase
   ```

   `pre-flight` is the active-phase default at goal creation. `paperflow-build` advances the pointer when the phase empties.

7. **Render the Goal HTML.** Read the full subtree via `bd show $GOAL_ID --json` + `bd list --label goal-<slug> --json`. Write `~/docs/paperflow/goals/<slug>/index.html` with: ingress (vision + overall progress), one section per phase in order (active phase highlighted, per-phase progress bar), tasks listed under their phase, action bar at the bottom routing through the bridge. The auto-open hook fires on Write and reuses the existing tab via cmux.

## Questionnaire on open

When the Goal lacks shape — broad scope, multiple axes of variation, or expensive to redo — write a **questionnaire** before drafting any plan. Skip for trivially-shaped work. The trigger is judgment, not a rule; anchor against these case → outcome pairs:

- *Case: "add a button to clear the form"* → **skip** (clear shape, single axis, cheap to reverse).
- *Case: "fix the off-by-one in date parser"* → **skip** (well-defined, has tests).
- *Case: "bump mermaid from 10 to 11"* → **skip** (single-axis dependency upgrade).
- *Case: "redesign the onboarding flow"* → **write** (broad scope, multiple axes, expensive to redo).
- *Case: "make paperflow work for teams"* → **write** (success criteria fuzzy, preferences unknown).
- *Case: "choose between server-side and edge rendering"* → **write** (architectural, hard to undo).

**The artifact:** `~/docs/paperflow/questionnaires/<YYYY-MM-DD>-<slug>-questionnaire.html`. Reuses `/paperflow/_lib/grill.{css,js}` — set `window.GRILL.kind = "questionnaire"` and `window.GRILL.goalId = "$GOAL_ID"`. Six categories: *scope · constraints · preferences · context · success criteria · open decisions*. 5–10 questions; `recommendation` is optional (omit when you genuinely don't have a pick). The shape is locked in `examples/example-questionnaire.html` — copy that file as the starting template.

**Stall handling:** open the questionnaire URL alongside the Goal HTML and wait. If the user goes silent past the next prompt, **nudge once** by repeating the URL. If still no answers, proceed without and append one JSONL line to `~/.paperflow/questionnaire-skips.log`: `{"ts": "<iso>", "goal_id": "<id>", "questionnaire_path": "<abs path>", "reason": "stall"}`.

**Output routing:** when answers come back through the bridge ("Questionnaire answers for…" header + `Goal: <id>` line), fold them into the Goal vision via `bd update $GOAL_ID --description "<refined>"` and re-snapshot the Goal HTML. The questionnaire bears `<filename>-answered.json` after successful submit — `paperflow-resume` uses that sidecar to detect unfinished forms across sessions.

## Sub-actions

- **Snapshot** — re-run step 7 against the live Beads state. No mutations to Beads. Refreshes the Goal HTML.
- **Archive** — `bd update $GOAL_ID --close`. Closes every still-open phase-task as a side effect (only legal when no work-tasks remain open). Updates the Goal HTML status to `closed`.
- **Edit vision** — `bd update $GOAL_ID --description "<new>"` then re-render.

## Artifact

- `~/docs/paperflow/goals/<slug>/index.html` — the Goal HTML, full Goal → Phase → Task subtree rendered.
- `<repo>/.paperflow/active-goal` — single-line pointer, Beads goal-task ID.
- `<repo>/.paperflow/active-phase` — single-line pointer, Beads phase-task ID.
- A new goal-task plus three phase-tasks in Beads, with three `bd dep add` edges.

## Beads commands

| Verb | Purpose |
|---|---|
| `bd init` | Bootstrap Beads in the repo (first goal only). |
| `bd create … --label kind:goal --label goal-<slug>` | Create the goal-task. |
| `bd create … --label kind:phase --label goal-<slug> --label phase-<name>` | Create a phase-task (×3 by default). |
| `bd dep add <phase-task> <goal-task>` | Attach phase under goal. |
| `bd show <goal-task-id> --json` | Read goal metadata for HTML render. |
| `bd list --label goal-<slug> --json` | Read full subtree for HTML render. |
| `bd update <goal-task-id> --description "…"` | Edit vision. |
| `bd update <goal-task-id> --close` | Archive. |
| `bd compact` | Run when goal-label exceeds ~50 tasks. |

## Don't

- Don't create a `goal.json` sidecar. Beads is the single source of truth — no parallel JSON.
- Don't force the 3-phase default on existing Goals. If a user has renamed or added phases, preserve them.
- Don't skip the `kind:goal` and `kind:phase` labels — they're the only discriminator between layers.
- Don't forget to write both pointer files. The active-phase pointer is mandatory; statusline and `paperflow-build` both rely on it.
