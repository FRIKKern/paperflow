---
name: plan
description: Use when the user says "plan X", "draft a plan for…", "grill this plan", "revise the plan after grill", or wants to design the task graph for the active Goal. paperflow's signature move. Three internal phases — draft → grill → revise. Grill is mandatory by default. The skill writes a plan HTML to `~/docs/paperflow/plans/<date>-<slug>.html`, then materialises plan steps as Beads work-tasks under the active phase via `bd create` + `bd dep add` for ordering. Brainstorming, writing-plans, and structural review all live here.
---

# plan

Design the task graph within phases. The orchestrator delegates the long-form writing to a subagent; the orchestrator turns the subagent's verified output into work-tasks `bd dep add`ed to the appropriate phase-task.

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
| "plan X" / "draft a plan for…" | The user wants to execute, not design — see `/paperflow:build` |
| "grill this plan" / "stress-test the plan" | The work is one-shot and has no structure |
| "revise the plan after grill" | No active goal — open one with `/paperflow:goal` first |
| Spec exists; needs implementation steps | Spec doesn't exist yet — write the spec first |

## Process

The skill walks three internal phases — draft, grill, revise — within a single Goal. Each phase delegates to a subagent for the actual writing; the orchestrator owns context, claims, and Beads mutations. A **questionnaire** may precede the draft when the task lacks shape (see below); questionnaire and grill never both compose on the same plan.

### Questionnaire before draft

Fire a **questionnaire** when the user lobs in a task whose shape isn't clear from one sentence — broad scope, multiple axes, or expensive to redo. Skip for trivially-shaped work. Anchor against these case → outcome pairs:

- *Case: "rename grill.js to form.js"* → **skip** (mechanical refactor, single axis).
- *Case: "fix the typo in the onboarding header"* → **skip** (trivial).
- *Case: "add a small CLI flag --json"* → **skip** (clear shape, cheap to reverse).
- *Case: "add an audit-log feature"* → **write** (scope/constraints unclear: which events? retention? UI surface?).
- *Case: "pick a state library"* → **write** (multi-axis preference call, hard to reverse later).
- *Case: "design the plugin system"* → **write** (architectural, multiple axes, expensive to redo).

**The artifact:** `~/docs/paperflow/questionnaires/<YYYY-MM-DD>-<slug>-questionnaire.html`. Reuses `/paperflow/_lib/grill.{css,js}` — set `window.GRILL.kind = "questionnaire"` and `window.GRILL.goalId = "<active-goal-id>"`. Six categories: *scope · constraints · preferences · context · success criteria · open decisions*. 5–10 questions; `recommendation` is optional. Copy `examples/example-questionnaire.html` as the starting template.

**Stall handling:** surface the questionnaire URL before any plan HTML exists. If the user goes silent past the next prompt, **nudge once** with the URL repeated. If still no answers, proceed to Phase A (draft) without them and append one JSONL line to `~/.paperflow/questionnaire-skips.log`: `{"ts": "<iso>", "goal_id": "<id>", "questionnaire_path": "<abs path>", "reason": "stall"}`.

**Output routing:** when answers arrive ("Questionnaire answers for…" + `Goal: <id>` line), fold them into the Phase A subagent brief — they tighten scope, name preferences, and surface success criteria the draft would otherwise have to guess at. The questionnaire informs the plan; it does **not** loop into the grill.

### Phase A — Draft

_Section structure adapted from `obra/superpowers/skills/writing-plans` and `brainstorming` (MIT) — see `THIRD-PARTY-CREDITS.md`._

1. **Read the active goal-task** to get the slug and vision:

   ```bash
   bd show "$(cat <repo>/.paperflow/active-goal)" --json
   ```

2. **Read the active phase pointer** to know which phase the new work-tasks attach under:

   ```bash
   bd show "$(cat <repo>/.paperflow/active-phase)" --json
   ```

3. **Spawn a subagent.** Subagent default: `paperflow-doc-writer` — read/write/edit only, cannot shell out, ideal for the article-style HTML draft. Fall back to `general-purpose` only when the task crosses categories. Brief: source spec + goal vision + active phase + the article-style HTML template (eyebrow, H1, byline, ingress, body sections with Mermaid figures + tables, ordered step list with explicit dependency edges between steps). Output path:

   ```
   ~/docs/paperflow/plans/<YYYY-MM-DD>-<slug>.html
   ```

   **Every paperflow HTML the subagent writes MUST include** `<script>window.PAPERFLOW_GOAL_ID = "<goal-id>";</script>` near the existing `window.DOC_PATH` block — applies to plans, grills, and questionnaires alike. The goal-path rail reads this to know which Goal's events to show. (Questionnaires also continue to set `window.GRILL.goalId` for the existing submit-routing path; the two coexist.)

   The subagent returns the URL plus a JSON list of plan steps: `[{ id, title, deps: [step-id…] }]`.

   **After the doc-writer subagent returns**, the orchestrator dispatches `paperflow-cmux-verifier` (see `agents/paperflow-cmux-verifier.md`) with the doc URL. The verifier runs `paperflow-doc-verify <url>` once and returns a one-line `PASS|WARN|FAIL|SKIP: <reason>` verdict. **PASS** → close the doc-write task. **WARN** → close + log. **FAIL** → route to debug (doc-write task stays claimed). **SKIP** (cmux not detected, or the docs surface isn't bound yet) → close — no regression vs the pre-cmux flow.

4. **Materialise plan steps as Beads work-tasks.** Done by the orchestrator directly (Beads ceremony is exempt from subagent dispatch — see paperflow-thresholds). For each step in the returned list, run:

   ```bash
   bd create "<step title>" --label goal-<slug>
   bd dep add <work-task> <active-phase-task>
   ```

   Then encode intra-phase order via `bd dep add <child> <parent>` for any step that depends on another step.

   **File-claim labels at creation time.** When the plan step names predicted files (per the file-scope-decomposition discipline below), attach them as `file-claim:<path>` labels on the work-task right away — the build orchestrator's pre-dispatch check will then see them without an extra round trip:

   ```bash
   ~/.local/bin/paperflow-claim-files claim <work-task-id> <path1> <path2> ...
   ```

   Plans whose steps don't yet name file scope are fine — `/paperflow:build` will ask the subagent to declare scope at dispatch time and add the labels then.

### Phase B — Grill (mandatory unless explicitly skipped)

_Section structure adapted from `obra/superpowers/skills/brainstorming` (MIT) — see `THIRD-PARTY-CREDITS.md`._

1. **Spawn a subagent.** Subagent default: `paperflow-researcher` — read-only, cannot accidentally edit while generating questions. Fall back to `general-purpose` only when the task crosses categories. (The grill HTML write itself is a follow-on `paperflow-doc-writer` dispatch.) The first dispatch reads the just-written plan in full and generates 8–15 pointed questions across these categories: architecture, edge cases, failure modes, observability, scope, security, operations, testing, open decisions. Each question carries a `rationale`, a `recommendation`, a `recommendationReason`, and almost always a Mermaid `diagram`.

2. **Write the grill HTML** to:

   ```
   ~/docs/paperflow/grills/<YYYY-MM-DD>-<slug>-grill.html
   ```

   Use the shared renderer at `/paperflow/_lib/grill.{css,js}`. Embed `window.CLAUDE_TARGET` from `~/.local/bin/paperflow-target <grill-html-path>` (the path argument is required — without it the helper aborts with `register-failed`, which prevents shipping a doc whose `doc_nonce` was never registered with the bridge).

3. **Wait for the user to fill the form and click Submit.** The bridge delivers a message starting with `Grill answers for <plan>:`. Re-enter Phase C with the answers in scope.

To skip the grill (rare; only for trivial revise-only changes), the user must explicitly say "skip grill".

### Phase C — Revise

1. **Read the grill answers** and decide what to change in the plan and what to change in the work-tasks.
2. **Re-write the plan HTML** with the answers integrated.
3. **Update Beads.** New steps → new work-tasks via `bd create` + `bd dep add`. Reordered steps → re-add dependency edges. Deleted steps → `bd update <id> --close` (or `--delete` if the step never started).
4. **Offer the user three exits:** re-grill the revised plan; hand off to `/paperflow:build` to start executing; or stop and let it sit.

## Artifact

- `~/docs/paperflow/plans/<date>-<slug>.html` — the plan HTML.
- `~/docs/paperflow/grills/<date>-<slug>-grill.html` — the grill HTML (when grill ran).
- N work-tasks in Beads, each `bd dep add`ed to the active phase-task, with intra-phase dependency edges encoding order.

## Beads commands

| Verb | Purpose |
|---|---|
| `bd show <goal-task-id> --json` | Read goal metadata + slug. |
| `bd show <phase-task-id> --json` | Read active phase. |
| `bd create "<step>" --label goal-<slug>` | Create a work-task. |
| `bd dep add <work-task> <phase-task>` | Attach work-task beneath active phase. |
| `bd dep add <child> <parent>` | Encode intra-phase order. |
| `bd update <id> --close` / `--delete` | Drop steps removed during revise. |

## Simplify (sub-action)

A "Simplify" button surfaces on every plan, spec, and grill HTML — a sub-action of `/paperflow:plan`, not a separate skill (the 8/8 cap holds). One click triggers a leaning-pass subagent that returns a tighter version of the doc; a two-tier verification gate decides whether the candidate lands as a new branch on the goal-path rail.

| Step | What happens |
|---|---|
| 1. Click | Browser POSTs to `localhost:8766/simplify` with `{doc_path, goal_id}` |
| 2. Bridge | Spawns leaning-pass subagent (`claude --print` + `lib/simplify-leaning-pass-brief.md`) |
| 3. Structural gate | `bin/paperflow-simplify-verify` checks Mermaid count, H2 hierarchy, bound decisions, no fabricated URLs |
| 4. Verification gate | Second subagent (`lib/simplify-verification-brief.md`) returns `PASS:` / `FAIL:` |
| 5. Land | Both PASS → `kind:event` task on `branch:simplified-<n>` parented to the source doc's last event; sidecar HTML at `~/.paperflow/events/<id>.html` |
| 6. Reject path | Any FAIL → no event; one line appended to `~/.paperflow/simplify-failures.log` |

**Trim categories the leaning pass attempts** (verbatim from `lib/simplify-leaning-pass-brief.md`): verbose phrasing, redundancy, example bloat, low-signal bullet sub-items, hedging words. **Never cut**: Mermaid figures, H2 headings, bound decisions, outbound URLs, the ingress.

**Idempotence.** Re-running Simplify on an already-simplified doc may yield further reduction or none — the gate fails the no-meaningful-change case as a structural-fail or a verification `FAIL: no reduction`.

**Accept / Reject.** When a `branch:simplified-*` node is selected on the rail, the rail surfaces Accept / Reject controls. Accept calls `POST /simplify/accept` — bridge writes the simplified payload back to the source doc on disk and relabels the event from `branch:simplified-<n>` to `branch:main`. Reject calls `POST /simplify/reject` with an optional reason — bridge runs `bd close <event-id> --reason …`.

**Recoverability.** The parent event is always click-jump-recoverable from the rail; the source HTML on disk is unchanged until the user explicitly accepts.

## Don't

- Don't skip the grill silently. If a plan ships without a grill, the user must have opted out by name.
- Don't write a plan when no Goal is active. Point the user at `/paperflow:goal` first.
- Don't attach work-tasks to the goal-task directly — always under a phase-task. The active-phase pointer says which.
- Don't materialise work-tasks until the plan HTML is written and reviewed. The plan HTML is the artifact; the Beads tasks track its execution.
