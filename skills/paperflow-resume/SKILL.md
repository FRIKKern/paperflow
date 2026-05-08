---
name: paperflow-resume
description: Use when the user says "/resume", "resume", "what was I working on", "list goals", "switch to goal X", or wants to pick up an existing Goal in this repo. Mirrors Claude Code's `/resume` for paperflow Goals. Lists Goals via Beads, presents a numbered selection menu, on pick writes new `.paperflow/active-goal` and `.paperflow/active-phase` pointers (defaulting to the first incomplete phase), and triggers the auto-open hook to display the chosen Goal HTML. Read-only on Beads — only mutates the two pointer files.
---

# paperflow-resume

The lifecycle-closing skill — equivalent to Claude Code's `/resume`, but for Goals. The user invokes it; the orchestrator lists Goals as a numbered list; the user picks; the skill flips pointers and opens the Goal HTML via cmux tab-reuse.

## When to fire

| Use this skill when | Skip when |
|---|---|
| "/resume" / "resume" | Active goal already covers the current work |
| "what was I working on" | New work — see `paperflow-goal` |
| "list goals" / "show open goals" | The user wants Beads details on one task — `bd show <id>` |
| "switch to goal X" / "make goal X active" | No goals exist in this repo yet |

## Process

1. **Enumerate Goals in this repo:**

   ```bash
   bd list --type epic --json
   ```

   This returns every goal-task — open, closed, snapshotted — via Beads' native epic type. (Legacy Goals carrying only the older `kind:goal` label are folded in by the orchestrator with a one-time fallback query.) The orchestrator filters / sorts by `last-touched` if available.

2. **Present a numbered list** to the user. Compact: title, slug, status, last-touched. Highlight the currently-active goal (if any).

   ```
   1. ✱ onboarding-revamp · phase 2/3: build · 4/9 tasks · 2 hours ago
   2.   payments-rewrite · phase 1/3: pre-flight · 1/6 tasks · yesterday
   3.   docs-ia-cleanup · closed · 3 days ago
   ```

   **Cross-instance scope hints.** paperflow's active-goal pointer is per-instance (per cmux workspace, or per Claude Code session). Two instances can hold different active Goals at once without colliding. To surface that, fold the scope map into the listing:

   ```bash
   paperflow-active-scope --list-all   # JSON of every scope's {goal, phase}
   ```

   Annotate each Goal in the numbered list with the scopes it's currently active in (e.g. "paperflow-j08 — last active in cmux-workspace-16"). The `bd list --type epic --status open` output is the source of truth for which Goals exist; the scope map is annotation only.

   **Umbrella grouping.** After fetching open Goals via `bd list --type epic --status open --json`, group by any `umbrella-<slug>` label. Goals without an umbrella render flat. Goals sharing one umbrella render under a heading:

   ```
   ▾ <umbrella-slug> (umbrella, N goals)
       paperflow-XYZ  · <title>     <status icon>
       paperflow-ABC  · <title>     <status icon>
   ```

   When `N == 1` (only one Goal carries the umbrella), skip the heading and render that single Goal flat. Umbrella headings are sorted alphabetically; ungrouped Goals follow.

3. **Wait for the user's pick** — by number, by slug, or by partial-match. Resolve to a goal-task ID.

4. **Read the chosen goal's metadata + slug:**

   ```bash
   bd show <chosen-goal-id> --json
   ```

5. **Find the first incomplete phase under it:**

   ```bash
   bd list --label goal-<slug> --label kind:phase --json \
     | jq '.[] | select(.status != "closed")' \
     | head -1
   ```

   That phase-task ID becomes the new active-phase. If all phases are closed, the active-phase points at the last phase (review by default) and the orchestrator surfaces "Goal complete; nothing to resume." If zero phases exist, the active-phase pointer is left empty (Goal-level `bd ready` applies).

6. **Write the pointer files** — per-repo (unchanged) plus the per-instance scoped global pointers via the helper:

   ```bash
   echo "<goal-task-id>"  > <repo>/.paperflow/active-goal
   echo "<phase-task-id>" > <repo>/.paperflow/active-phase
   paperflow-active-scope --write goal  "<goal-task-id>"
   paperflow-active-scope --write phase "<phase-task-id>"
   ```

   The per-repo files stay single-line; lookup walks up from cwd to the nearest `.paperflow/` directory. The scoped writes target this Claude Code instance only — sibling instances (other cmux workspaces, other terminals) keep their own active goals.

7. **Scan for unfinished questionnaires.** Before opening the Goal HTML, look for any questionnaire HTML belonging to this Goal that the user opened but never submitted:

   ```bash
   find ~/docs/paperflow/questionnaires -name "${SLUG}-*-questionnaire.html" 2>/dev/null
   ```

   For each match, check whether a sibling `<filename>-answered.json` exists. **If absent, the questionnaire is unfinished** — surface its live-reload URL alongside the Goal HTML in the resume output so the user can pick up where they left off. The "answered" sidecar is written by `lib/grill.js` on successful submit (single line: `{"submitted_at": "<iso>"}`); its absence is the canonical signal for "still owes answers".

8. **Trigger the auto-open hook** by writing (or touching) the Goal HTML at `~/docs/paperflow/goals/<slug>/index.html`. cmux's URL handler de-dupes by URL — `placement=reuse` if the tab is already open, `placement=new` otherwise. Same-URL-same-surface contract.

9. **Update statusline cache.** Re-render `~/.paperflow/statusline.txt` so the next prompt cycle reflects the new active goal + phase.

## Optional: cross-repo (v1.x)

A flag (`--cross-repo`) walks known paperflow-using repos and aggregates their Goals lists. Default is per-repo. Out of scope for v1 if it adds meaningful complexity.

## Edge cases

| Situation | Behaviour |
|---|---|
| Chosen Goal has zero phases | Active-phase pointer is empty (or absent). Goal-level `bd ready` applies. |
| All phases are closed | Active-phase points at the last phase; surface "Goal complete; nothing to resume." |
| `active-phase` pointer references a deleted phase | Detect via `bd show` failure; fall back to first incomplete phase under the active goal-task; rewrite pointer. |
| Beads database missing or corrupt | Surface the underlying `bd` error verbatim; don't silently flip pointers. |
| User picks a slug that doesn't exist | Re-prompt with the numbered list. |

## Artifact

- `<repo>/.paperflow/active-goal` — single-line pointer, Beads goal-task ID.
- `<repo>/.paperflow/active-phase` — single-line pointer, Beads phase-task ID (or empty).
- A browser tab open at `~/docs/paperflow/goals/<slug>/index.html` (reused if already open).
- Refreshed `~/.paperflow/statusline.txt`.

## Beads commands

| Verb | Purpose |
|---|---|
| `bd list --type epic --json` | Enumerate Goals in this repo (Beads-native epic type). |
| `bd show <goal-task-id> --json` | Read metadata + slug for the chosen Goal. |
| `bd list --label goal-<slug> --label kind:phase --json` | Find first incomplete phase. |

**Read-only on Beads.** This skill writes no Beads tasks — only pointer files.

## Don't

- Don't mutate Beads. Resume is pointer-flipping, not state-changing.
- Don't force a new tab. cmux's tab-reuse contract handles it.
- Don't auto-pick a Goal silently. The user's pick is the input — present the list and wait.
- Don't lose the active-phase invariant. If the chosen Goal has phases, the active-phase pointer must end up populated (or explicitly empty for zero-phase Goals).
