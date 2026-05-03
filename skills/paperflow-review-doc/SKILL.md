---
name: paperflow-review-doc
description: Use as the final step of every paperflow doc-writing skill (discuss, grill-plan, mission-create, mission-snapshot, write-changelog, pre-flight-capture) and any time the user says "review this doc", "validate the spec", "validate the plan", "validate the grill", or "check the changelog". Runs paperflow-validate (Mermaid syntax + render checks) and optionally a deeper browser visual review. Returns { ok, issues, suggested_fixes } so the caller can iterate before reporting the URL.
---

# paperflow-review-doc

Catch broken Mermaid (the "Syntax error in text" bomb icon) and render failures BEFORE the URL is handed to the user. Two layers, fastest first.

## When to fire

| Use this skill | Skip |
|---|---|
| Final step of any paperflow doc write (discuss / grill-plan / mission-create / mission-snapshot / write-changelog / pre-flight-capture) | Doc has no Mermaid and no JS rendering |
| User says "review this doc", "validate the X", "check the changelog" | Pure prose with no figures |
| Spec/plan with many diagrams just landed | Trivial single-paragraph note |

The PostToolUse hook (`~/.claude/hooks/validate-paperflow-doc.sh`) already runs Layer 1 automatically on every Write|Edit of a paperflow doc — so by the time this skill is invoked, the writing agent will already have seen any failures via a system-reminder. This skill exists to **explicitly** verify and (optionally) escalate to Layer 2.

## Process

### Layer 1 — static validation (always)

Run:

```
~/.local/bin/paperflow-validate <abs-path-to-html>
```

- Exit `0`: all Mermaid blocks parse. Layer 1 passes.
- Exit `2`: at least one block fails. Read the JSON `failed[]` array — each entry has `kind` (`pre` or `diagram`), `qid` (for grills), `line_estimate`, `error_message`, and `source_excerpt`. Return findings to the caller.

### Layer 2 — browser visual review (optional)

Trigger Layer 2 only if:
- The user explicitly asked for a visual review, OR
- The doc is high-risk: long plan with many diagrams, changelog with media, mission, audit.

Spawn a `visual-investigator` subagent (Chrome DevTools MCP). Brief:

> Load `http://localhost:8765/<path-relative-to-docs>` (e.g. `superpowers/grills/2026-05-04-visual-capture-stack-grill.html`). Wait 3 s for Mermaid to render. Then:
> 1. Scan the DOM for elements with text content matching `/Syntax error/i` or class containing `error-icon`.
> 2. Capture any console errors emitted during render.
> 3. Take a single full-page screenshot for evidence.
>
> Return strict JSON: `{ ok: bool, issues: [ { type: "syntax-error"|"console-error"|"missing-render", text, selector? } ], screenshot_path? }`. No prose.

## Return shape

```json
{
  "ok": true
}
```

OR

```json
{
  "ok": false,
  "issues": [
    {
      "layer": "static",
      "kind": "diagram",
      "qid": "q2",
      "line_estimate": 75,
      "error_message": "Lexical error on line 10. Unrecognized text...",
      "source_excerpt": "flowchart LR\n  U[\"URL\"] --> T{\"detection?\"}\n..."
    }
  ],
  "suggested_fixes": [
    "Q2 diagram: edge label `-.localhost/127/.local/.->` contains slashes that confuse the lexer. Replace with a quoted label, e.g. `-.\"localhost / 127 / .local\".-> NO` or remove the dotted-edge label entirely."
  ]
}
```

The caller iterates: re-write the offending block, re-save (the PostToolUse hook re-runs Layer 1), call this skill again. Cap at 3 iterations — if still failing, return the URL with a clear note that some Mermaid may not render and let the user decide.

## What this skill is not

- **Not a content review.** It checks render-correctness, not whether the prose is good.
- **Not a code review.** It validates HTML output of paperflow doc skills, not source.
- **Not a replacement for the user opening the page.** Layer 2 is a sanity check, not a substitute for human eyes on a high-stakes artifact.
