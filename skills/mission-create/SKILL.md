---
name: mission-create
description: Use when the user says "start a mission", "new mission for X", "let's begin a project to do Y", or kicks off any non-trivial multi-artifact piece of work that will span multiple specs / plans / grills. Picks a kebab-case slug, spawns a subagent to write a paired HTML + JSON mission file under ~/docs/paperflow/missions/, and marks it active in ~/.paperflow/active-mission so mission-snapshot and mission-continue know which mission to operate on.
---

# mission-create

A **mission** groups related artifacts (specs, plans, grills, notes, changelogs) under a single vision. One active mission at a time. The mission HTML is the human-readable article; the JSON sidecar is what `paperflow-continue` consumes to spawn a fresh Claude session with full context.

## When to fire

| Use this skill when | Skip when |
|---|---|
| User says "start a mission" / "new mission" / "let's begin a project to do X" | Single one-off question or fix |
| Work will span multiple specs / plans / grills | Single spec or single plan |
| User wants to be able to continue this work in a fresh session later | Stateless throwaway exploration |

## Process

1. **Pick a slug.** Kebab-case, 2–4 words. Date-prefix it: `<YYYY-MM-DD>-<slug>` (e.g. `2026-05-02-paperflow-v2`). Today's date in `YYYY-MM-DD` form. Confirm the slug with the user only if ambiguous.

2. **Spawn a subagent (`subagent_type: general-purpose`)** to write both files in parallel:
   - `~/docs/paperflow/missions/<date>-<slug>.html` — article-style HTML mirroring the spec template.
   - `~/docs/paperflow/missions/<date>-<slug>.json` — machine-readable sidecar.

   Brief the subagent with:
   - Mission name (human-readable), vision (1–2 sentences), and any artifacts that already exist.
   - The exact JSON schema (below).
   - The exact HTML structure (below).
   - The current `paperflow-target` JSON (run `~/.local/bin/paperflow-target` first and pass it).
   - "Return only the URL when done. Do not summarize."

3. **Write `~/.paperflow/active-mission`** with just the slug on one line:
   ```
   <date>-<slug>
   ```

4. **Reply** with the localhost URL: `http://localhost:8765/paperflow/missions/<date>-<slug>.html`.

## JSON schema

```json
{
  "slug": "<date>-<slug>",
  "name": "Human-readable name",
  "vision": "1–2 sentence why this exists",
  "created": "YYYY-MM-DDTHH:MM:SSZ",
  "artifacts": [
    { "type": "spec", "path": "/paperflow/specs/2026-05-02-...html", "title": "..." }
  ],
  "decisions": [
    { "ts": "...", "decision": "...", "rationale": "..." }
  ],
  "progress": { "done": ["..."], "in_progress": ["..."], "next": "concrete one-liner" },
  "open_questions": ["..."],
  "resume_prompt": "You are continuing the <name> mission. Read /Users/frikkjarl/docs/paperflow/missions/<slug>.html in full. Then do: <next-step>."
}
```

`type` values: `spec` | `plan` | `grill` | `note` | `changelog`. `artifacts` and `decisions` may be empty arrays at create time. `progress.next` must be a concrete one-liner — that becomes the tail of the resume prompt.

## HTML structure

Mirror the JSON. Article-style typography (eyebrow, H1, byline, ingress, H2 sections). Mermaid 10 from CDN. Sections in this order:

- **Eyebrow** — `Mission`
- **H1** — the human-readable name
- **Byline** — `<date>` · `<slug>` · status (e.g. "active")
- **Ingress** — the vision (2–3 sentences expanded from the JSON `vision`)
- **H2 Artifacts** — table or bullet list of every artifact (link via `/paperflow/<type>s/<file>`). Empty section if none yet.
- **H2 Progress** — three subsections: Done / In progress / Next step. The `next` is the concrete one-liner from the JSON.
- **H2 Decisions** — chronological list, each with rationale.
- **H2 Open questions** — bullet list.
- **H2 Mission map** — Mermaid diagram showing how the artifacts hang together (vision at the top, artifacts as nodes, edges showing dependency / build order).
- **Tail** — the standard `window.CLAUDE_TARGET` + `window.DOC_PATH` + `<script src="/paperflow/_lib/doc.js">` so the mission HTML gets Continue / Snapshot buttons.

Use the same article CSS as specs/plans (inline `<style>` block; copy from a recent spec for consistency).

## Active mission

`~/.paperflow/active-mission` is a single file with one line: the current mission slug. `mission-snapshot` and `mission-continue` read it. If the user starts a new mission while one is active, overwrite — only one active mission at a time.

## Final review (mandatory)

Before returning the URL to the user, invoke the `paperflow-review-doc` skill on the mission HTML path. If it returns `ok: false`, fix the offending blocks (typically Mermaid syntax errors in the mission map) and re-save. Iterate up to 3 times. If still failing after 3 iterations, return the URL with a clear note that some Mermaid blocks may not render correctly — don't pretend it shipped clean.

## Don't

- Don't proactively tag existing specs/plans/grills with mission meta tags — that's phase 2.
- Don't write the spec/plan body inside the mission HTML — it's a hub, not a doc.
- Don't omit the JSON sidecar. The launcher consumes the JSON, not the HTML.
- Don't omit the `<script>` tail — without it, the Continue / Snapshot buttons won't appear on the mission page.
