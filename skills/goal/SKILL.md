---
name: goal
description: Use when the user says "start a goal", "open a goal for X", "snapshot the goal", "save current state", "checkpoint this work", "continue this goal in a new tab", "resume in fresh session", "archive the goal", "what's the active goal?", "merge goal X into Y", "fold this goal into another", or kicks off any non-trivial multi-artifact piece of work. Creates a goal-task in Beads with `kind:goal`, auto-creates three default phase-tasks (pre-flight, build, review) underneath, sets the per-repo `.paperflow/active-goal` and `.paperflow/active-phase` pointers, and renders the Goal HTML at `~/docs/paperflow/goals/<slug>/index.html`. Sub-actions: snapshot (refresh HTML + JSON sidecar), continue (spawn fresh Claude tab via paperflow-continue), archive (close Goal), merge (fold one open Goal into another as a new phase). Folds in the work that the legacy mission-create / mission-snapshot / mission-continue skills used to do.
---

# goal

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


<!-- BEGIN paperflow-step-0.5 -->
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
<!-- END paperflow-step-0.5 -->


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

2. **Pre-flight Beads.** Run `paperflow-doctor --ensure-bd` — it walks up from cwd to the nearest git repo root, runs `bd init` if `.beads/` is missing, and emits one JSON line on stdout (`{ok, action, db_path}`). Idempotent: re-running is a no-op.

3. **Create the goal-task:**

   ```bash
   bd create "<vision sentence>" \
       --type epic \
       --label goal-<slug>
   ```

   Capture the resulting task ID (e.g. `bd-a1b2`) into `$GOAL_ID`. The `--type epic` is Beads' native umbrella type — paperflow uses it as the data-layer name for a Goal. Drop the legacy `kind:goal` label on new Goals; closed Goals from before this migration keep their old labels.

   **`--umbrella <slug>` for multi-axis outcomes.** When a body of work spans more than one Goal — e.g. a redesign that touches onboarding, billing, and admin in parallel — pass `/paperflow:goal --umbrella <slug> "<vision>"`, which adds a `umbrella-<slug>` label on the goal-task. `/paperflow:resume` groups Goals sharing the same umbrella under one heading. The umbrella label is **optional and rare**; default Goal usage doesn't need it. To attach an umbrella mid-flight, run `bd label add <epic-id> umbrella-<slug>` on the open Goal.

3.5. **Led-to consent.** Many Goals continue earlier work — refining the same idea, picking up where a previous session paused. Capture that lineage as a Beads label so the rail and `/paperflow:resume` can show the chain. Schema-free, optional, asked once.

   First, query recent open Goals (last 7 days, excluding the one just created):

   ```bash
   bd list --type epic --status open --json 2>/dev/null \
     | jq -r --arg me "$GOAL_ID" '
         [.[] | select(.id != $me)
              | select(.created_at > (now - 86400*7 | strftime("%Y-%m-%dT%H:%M:%S")))
              | {id, title, created_at}]'
   ```

   **If 0 results:** skip the consent — fresh Goal, no continuation possible. Proceed to step 4.

   **If 1+ results:** score each candidate against the new vision string with a cheap heuristic — count common words of length ≥ 4 (lowercased, stripped of punctuation). A score ≥ 2 marks a candidate as "looks similar". Surface the highest-scoring similar candidate FIRST in the question.

   Then `AskUserQuestion` with up to 4 options:

   - **Fresh Goal — no continuation** (default)
   - **Continuation of: \<recent Goal title 1\>** (the highest-scoring; if score ≥ 2, prefix with "Looks similar — ")
   - **Continuation of: \<recent Goal title 2\>** (second pick if available)
   - **Looks similar to \<X\> — merge instead?** (only if a candidate scored ≥ 3, suggests folding the new Goal into the older one via the merge sub-action)

   On **"Continuation of"**:

   ```bash
   bd update "$GOAL_ID" --add-label "led-from-${SOURCE_ID}"
   ```

   On **"merge instead"**: invoke the merge sub-action — `paperflow-goal-merge "$GOAL_ID" "$SOURCE_ID"` (the just-created Goal is the source; the older Goal is the target — we're folding the new Goal into the existing one). After the merge, the active-goal pointer needs to be updated to `$SOURCE_ID` and the skill exits early — no phase-tasks are created for what is now a merged-away Goal.

   On **"Fresh Goal"**: do nothing extra. Proceed to step 4.

   The `led-from-<source-id>` label is read-only metadata. The Goal-path rail surfaces it as a small "← led from <source>" breadcrumb at the top of the Goal HTML.

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

   `pre-flight` is the active-phase default at goal creation. `/paperflow:build` advances the pointer when the phase empties.

   **Mirror to the per-instance scoped pointer.** The `event-on-save.sh` hook walks up from the saved file's dir and from `$PWD`, but neither traversal reaches the dev repo when paperflow docs are saved under `~/docs/paperflow/...`. Mirror the active-goal id and active-phase id through the scope helper, which writes per-cmux-workspace (or per-Claude-Code-session) pointers so two instances never collide:

   ```bash
   paperflow-active-scope --write goal "$GOAL_ID"
   paperflow-active-scope --write phase "$PHASE_PREFLIGHT"
   ```

   On goal close (`bd update $GOAL_ID --close`) clear BOTH the per-repo pointer and the scoped global pointers:

   ```bash
   : > <repo>/.paperflow/active-goal
   paperflow-active-scope --clear
   ```

7. **Render the Goal HTML.** Subagent default: `paperflow-doc-writer` — the initial Goal HTML write is >50 lines of new HTML and crosses the prose threshold. Fall back to `general-purpose` only when the task crosses categories. (Snapshot re-renders that change ≤ 5 lines stay orchestrator-direct via the exempt list.) Read the full subtree via `bd show $GOAL_ID --json` + `bd list --label goal-<slug> --json`. Write `~/docs/paperflow/goals/<slug>/index.html` with: ingress (vision + overall progress), one section per phase in order (active phase highlighted, per-phase progress bar), tasks listed under their phase, action bar at the bottom routing through the bridge. The auto-open hook fires on Write and reuses the existing tab via cmux.

   **Every paperflow HTML you write MUST include** `<script>window.PAPERFLOW_GOAL_ID = "<goal-id>";</script>` near the existing `window.DOC_PATH` block. The goal-path rail (`lib/goal-path-rail.js`) reads this to know which Goal's events to show. Without it the rail falls back to a server-side `?source=<doc-path>` lookup — slower, and silent on freshly-created docs that don't yet have any events.

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

**Output routing:** when answers come back through the bridge ("Questionnaire answers for…" header + `Goal: <id>` line), fold them into the Goal vision via `bd update $GOAL_ID --description "<refined>"` and re-snapshot the Goal HTML. The questionnaire bears `<filename>-answered.json` after successful submit — `/paperflow:resume` uses that sidecar to detect unfinished forms across sessions.

## Sub-actions

- **Create** — the default at skill invocation. Steps 1–7 above. Explicit alias for clarity when the user says "open a goal" / "start a goal" / "create goal".

- **Snapshot** — re-run step 7 against the live Beads state. No mutations to Beads. Refreshes the Goal HTML at `~/docs/paperflow/goals/<slug>/index.html` AND writes a small JSON sidecar at `~/docs/paperflow/goals/<slug>/index.json` containing `{slug, goal_id, vision, snapshot_ts, resume_prompt}`. The `resume_prompt` is the one-line instruction a fresh Claude session reads to pick up: `"You are resuming the <slug> Goal. Read /Users/<user>/docs/paperflow/goals/<slug>/index.html in full, then continue work on the active phase."`. The `continue` sub-action consumes this sidecar.

- **Continue** — spawn a fresh Claude Code session in a new terminal tab, pre-loaded with the active Goal's resume_prompt.
  1. Read `<repo>/.paperflow/active-goal` (or via `paperflow-active-scope --read goal`) to get `$GOAL_ID`.
  2. Resolve the slug from `bd show $GOAL_ID --json` (label `goal-<slug>`).
  3. Run **snapshot** first to refresh `~/docs/paperflow/goals/<slug>/index.json`. If the sidecar doesn't exist yet, snapshot writes it.
  4. Invoke `~/.local/bin/paperflow-continue <slug>`. The launcher reads the sidecar's `resume_prompt`, detects the current terminal (tmux / iTerm / Apple Terminal / fallback), opens a new tab/window running `cd ~ && claude --dangerously-skip-permissions <resume_prompt>`.
  5. Reply with one short sentence — which terminal path was used + slug.

- **Archive** — `bd update $GOAL_ID --close`. Closes every still-open phase-task as a side effect (only legal when no work-tasks remain open). Updates the Goal HTML status to `closed`.

- **Merge** — fold one open Goal into another as a new phase. Triggered by "merge goal X into Y", "fold this goal into another", or surfaced from the led-to consent step's "merge instead" pick. Both Goals stay in Beads — the source is closed with a `merged-into-<target>` label, the target gains a new "Merged from <source>" phase-task that the source's existing phase-tasks now also depend on. Reversible at the bd level (re-open source, close merged phase). Implemented in `~/.local/bin/paperflow-goal-merge`:

  ```bash
  paperflow-goal-merge <source-id> <target-id>
  ```

  The helper:

  1. Validates both ids exist and are open epics.
  2. `bd create` a `kind:phase` task titled "Merged from \<src-title\> (was \<src-id\>)" under the target, with labels `kind:phase`, the target's `goal-<slug>`, and `phase-merged-from-<src-id>`.
  3. `bd dep add` from each of the source's existing phase-tasks → the new merged phase. Source's old dep edges to the source Goal stay intact (Beads dep removal is not part of paperflow's contract — we add lineage, never delete it).
  4. Rewrites every `~/docs/paperflow/` HTML whose `window.PAPERFLOW_GOAL_ID` equals the source id to point at the target. The goal-path rail then includes those docs in the target's history.
  5. `bd update <source> --status closed --add-label merged-into-<target> --description "<merge breadcrumb>"`.
  6. Emits a `kind:event` task labelled `event:goal-merged` + `branch:merged-from-<source>` under the target so the rail shows the merge.
  7. Prints a summary table: src/tgt ids + titles, # of phase-tasks moved, # of docs rewritten, new merged-phase id, rail event id.

  The merge flow re-parents source's phase-tasks under the target's new merged-phase, leaving the original source Goal closed with full lineage:

  ```mermaid
  flowchart LR
    subgraph Before
      G1["Goal: source<br/>(open)"]
      P1["pre-flight"] --> G1
      P2["build"]      --> G1
      P3["review"]     --> G1
      G2["Goal: target<br/>(open)"]
      Q1["pre-flight"] --> G2
      Q2["build"]      --> G2
    end
    subgraph After
      G1c["Goal: source<br/>(closed, label:<br/>merged-into-target)"]
      P1b["pre-flight"] --> G1c
      P2b["build"]      --> G1c
      P3b["review"]     --> G1c
      G2b["Goal: target<br/>(open)"]
      Q1b["pre-flight"]      --> G2b
      Q2b["build"]           --> G2b
      MP["Merged from source"] --> G2b
      P1b --> MP
      P2b --> MP
      P3b --> MP
    end
  ```

  After the merge, if the source Goal was the active Goal in this repo, the skill rewrites `<repo>/.paperflow/active-goal` to the target id (and clears `<repo>/.paperflow/active-phase` so `/paperflow:build` re-resolves it). The mirror through `paperflow-active-scope --write goal "$TARGET_ID"` keeps per-instance pointers consistent.

  **To reverse:** `bd update <source> --status open --remove-label merged-into-<target>` then `bd update <merged-phase-id> --status closed`. Doc rewrites are NOT auto-reversed — re-run with src/tgt swapped or `git checkout` the affected HTML.

- **Edit vision** — `bd update $GOAL_ID --description "<new>"` then re-render.

## Artifact

- `~/docs/paperflow/goals/<slug>/index.html` — the Goal HTML, full Goal → Phase → Task subtree rendered.
- `<repo>/.paperflow/active-goal` — single-line pointer, Beads goal-task ID.
- `<repo>/.paperflow/active-phase` — single-line pointer, Beads phase-task ID.
- A new goal-task plus three phase-tasks in Beads, with three `bd dep add` edges.

## Beads commands

| Verb | Purpose |
|---|---|
| `paperflow-doctor --ensure-bd` | Bootstrap Beads in the repo (first goal only — wraps `bd init`). |
| `bd create … --type epic --label goal-<slug>` | Create the goal-task (Beads-native epic; drops the old `kind:goal` label). |
| `bd label add <epic-id> umbrella-<slug>` | Attach a multi-Goal umbrella mid-flight. |
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
- Don't skip the `--type epic` flag on the goal-task or the `kind:phase` label on phase-tasks — they're the only discriminator between layers. (Legacy `kind:goal` Goals stay readable; new Goals use `--type epic`.)
- Don't forget to write both pointer files. The active-phase pointer is mandatory; statusline and `/paperflow:build` both rely on it.
