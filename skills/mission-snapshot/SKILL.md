---
name: mission-snapshot
description: Use when the user says "snapshot the mission", "save current state", "checkpoint this work", or before any big context handoff (compaction, tab swap, end-of-day). Refreshes the active mission's HTML + JSON sidecar with the latest artifacts, progress, decisions, open questions, and a fresh resume_prompt — so a new Claude session can pick up perfectly with mission-continue.
---

# mission-snapshot

Refresh the active mission's `<slug>.html` and `<slug>.json` with the current state of work. The JSON sidecar is what `paperflow-continue` reads to launch a fresh Claude session.

## When to fire

| Use this skill when | Skip when |
|---|---|
| User says "snapshot" / "save state" / "checkpoint" | No active mission |
| Context is filling up (>50%) and a fresh tab is imminent | Just finished a single spec/plan with no broader project |
| Before invoking `mission-continue` | Trivial single-task work |
| Major decision or artifact landed since last snapshot | Nothing changed since the last snapshot |

`mission-continue` calls this skill first — so when the user clicks **Continue** on a mission HTML, snapshot runs automatically.

## Process

1. **Read the active mission slug:**
   ```bash
   cat ~/.paperflow/active-mission
   ```
   If empty or missing, tell the user: "No active mission. Run `mission-create` first."

2. **Spawn a subagent (`subagent_type: general-purpose`)** to do the refresh. Brief it with:
   - The slug.
   - Path to the existing JSON: `~/docs/superpowers/missions/<slug>.json`.
   - Path to the existing HTML: `~/docs/superpowers/missions/<slug>.html`.
   - Instructions:
     - Read the existing JSON. Note the `created` timestamp.
     - Scan `~/docs/superpowers/{specs,plans,grills,notes,changelog}/` for HTML files modified since `created`. For each new file, append to `artifacts` with type, path (e.g. `/superpowers/specs/<file>`), and title (extract from `<h1>` or `<title>`).
     - Update `progress.done` / `progress.in_progress` / `progress.next` based on what's actually shipped vs in-flight (the subagent should look at recent file mtimes and the latest changelog, if any).
     - Add any new decisions made during this session (the main agent passes these in via the brief).
     - Refresh `open_questions` (the main agent passes these in).
     - Rewrite `resume_prompt` to reference the (updated) HTML and the new `progress.next`.
     - Update the HTML to mirror the new JSON (regenerate Artifacts / Progress / Decisions / Open questions sections; keep the eyebrow, title, vision, and `<script>` tail intact).
     - Bump the byline status if appropriate.
   - "Return only the URL when done. Do not summarize."

3. **Reply** with the URL: `http://localhost:8765/superpowers/missions/<slug>.html`.

## What the main agent passes to the subagent

- **New decisions** since the last snapshot — every "we decided X because Y" worth preserving across sessions.
- **Updated open questions** — what's still unresolved.
- **What's currently in-flight** — the one-liner that becomes `progress.in_progress[0]` and feeds `progress.next`.

If the main agent isn't sure, leave those fields untouched — but ALWAYS refresh `artifacts` (file scan) and `resume_prompt`.

## Don't

- Don't create a new mission. This skill operates on the active one only.
- Don't strip existing fields. Append / update; never delete unless explicitly told.
- Don't change the slug, `created` timestamp, or `vision`.
- Don't skip the resume_prompt rewrite — that's the whole point of the snapshot.
