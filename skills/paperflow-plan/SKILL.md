---
name: paperflow-plan
description: Use when the user says "plan X", "draft a plan for…", "grill this plan", "revise the plan after grill", or wants to design the task graph for the active Goal. paperflow's signature move. Three internal phases — draft → grill → revise. Grill is mandatory by default. The skill writes a plan HTML to `~/docs/paperflow/plans/<date>-<slug>.html`, then materialises plan steps as Beads work-tasks under the active phase via `bd create` + `bd dep add` for ordering. Brainstorming, writing-plans, and structural review all live here.
---

# paperflow-plan

Design the task graph within phases. The orchestrator delegates the long-form writing to a subagent; the orchestrator turns the subagent's verified output into work-tasks `bd dep add`ed to the appropriate phase-task.

## When to fire

| Use this skill when | Skip when |
|---|---|
| "plan X" / "draft a plan for…" | The user wants to execute, not design — see `paperflow-build` |
| "grill this plan" / "stress-test the plan" | The work is one-shot and has no structure |
| "revise the plan after grill" | No active goal — open one with `paperflow-goal` first |
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

3. **Spawn a subagent** (`subagent_type: general-purpose`) to write the plan. Brief: source spec + goal vision + active phase + the article-style HTML template (eyebrow, H1, byline, ingress, body sections with Mermaid figures + tables, ordered step list with explicit dependency edges between steps). Output path:

   ```
   ~/docs/paperflow/plans/<YYYY-MM-DD>-<slug>.html
   ```

   The subagent returns the URL plus a JSON list of plan steps: `[{ id, title, deps: [step-id…] }]`.

4. **Materialise plan steps as Beads work-tasks.** For each step in the returned list, run:

   ```bash
   bd create "<step title>" --label goal-<slug>
   bd dep add <work-task> <active-phase-task>
   ```

   Then encode intra-phase order via `bd dep add <child> <parent>` for any step that depends on another step.

### Phase B — Grill (mandatory unless explicitly skipped)

_Section structure adapted from `obra/superpowers/skills/brainstorming` (MIT) — see `THIRD-PARTY-CREDITS.md`._

1. **Spawn a subagent** to read the just-written plan in full and generate 8–15 pointed questions across these categories: architecture, edge cases, failure modes, observability, scope, security, operations, testing, open decisions. Each question carries a `rationale`, a `recommendation`, a `recommendationReason`, and almost always a Mermaid `diagram`.

2. **Write the grill HTML** to:

   ```
   ~/docs/paperflow/grills/<YYYY-MM-DD>-<slug>-grill.html
   ```

   Use the shared renderer at `/paperflow/_lib/grill.{css,js}`. Embed `window.CLAUDE_TARGET` from `~/.local/bin/paperflow-target` so the Submit button reaches this orchestrator session via the bridge.

3. **Wait for the user to fill the form and click Submit.** The bridge delivers a message starting with `Grill answers for <plan>:`. Re-enter Phase C with the answers in scope.

To skip the grill (rare; only for trivial revise-only changes), the user must explicitly say "skip grill".

### Phase C — Revise

1. **Read the grill answers** and decide what to change in the plan and what to change in the work-tasks.
2. **Re-write the plan HTML** with the answers integrated.
3. **Update Beads.** New steps → new work-tasks via `bd create` + `bd dep add`. Reordered steps → re-add dependency edges. Deleted steps → `bd update <id> --close` (or `--delete` if the step never started).
4. **Offer the user three exits:** re-grill the revised plan; hand off to `paperflow-build` to start executing; or stop and let it sit.

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

## Don't

- Don't skip the grill silently. If a plan ships without a grill, the user must have opted out by name.
- Don't write a plan when no Goal is active. Point the user at `paperflow-goal` first.
- Don't attach work-tasks to the goal-task directly — always under a phase-task. The active-phase pointer says which.
- Don't materialise work-tasks until the plan HTML is written and reviewed. The plan HTML is the artifact; the Beads tasks track its execution.
