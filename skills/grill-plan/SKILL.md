---
name: grill-plan
description: Use when the user clicks "Grill the plan" in a spec/plan HTML, asks to grill / stress-test / pressure-test a plan, or says "grill it". Reads the spec/plan, generates 8–15 pointed questions across categories (architecture, edge cases, failure modes, observability, scope, security, operations, testing, open decisions), and writes an HTML form to ~/docs/superpowers/grills/ using the shared renderer. The user fills out the form in browser, hits Submit, answers come back through claude-bridge for plan revision.
---

# Grill a plan

Critically examine a plan/spec to surface hidden assumptions, missing edge cases, contradictions, and failure modes. Generate pointed, specific questions — not generic ones — and let the user answer in a structured HTML form.

## Input

A path to a spec or plan HTML, e.g.:

```
~/docs/superpowers/specs/2026-05-02-openclaw-handoff-design.html
```

## Process

**Subagent-first.** Per paperflow's default workflow, delegate the read + draft to a subagent (`subagent_type: general-purpose`). Brief: "Read this plan in full, generate 8–15 pointed questions following the schema below, write the grill HTML to `<path>` using the shared renderer at `/superpowers/_lib/grill.{css,js}`. Embed `window.CLAUDE_TARGET` from `paperflow-target`. Return only the URL — no summary." The main session reports the URL + a one-line framing of what the grill probes.

1. **Read the plan in full.** Don't skim. Understand what it claims, what it omits, what tradeoffs it picked, where the load-bearing decisions are.

2. **Generate 8–15 questions across these categories** (skip ones that don't apply):

| Category | Probes for |
|---|---|
| Architecture | Boundaries, contracts, isolation, coupling |
| Edge cases | Concrete scenarios the plan doesn't address |
| Failure modes | What breaks, what cascades, what recovers |
| Observability | How we know it worked or failed |
| Scope | Doing too much vs too little |
| Security / Trust | Credentials, blast radius, irreversible actions |
| Operations | Deploy, rollback, versioning, migration |
| Testing / Verification | What proves this works |
| Open decisions | Choices the plan punted on |

3. **Pick the right input type per question:**

| Type | When |
|---|---|
| `open` | Nuance matters; free text is the only honest answer |
| `single` | Clear A/B/C choice with named options |
| `multi` | "Select all that apply" |
| `yesno` | Binary decision |
| `scale` | Prioritization or intensity (default 1–5) |

4. **Be specific.** Bad: *"What about edge cases?"* Good: *"What happens if OpenClaw's auto-execute succeeds but the resulting Mac state is wrong — e.g., it clicked the wrong dialog button?"*

5. **Every question needs a `rationale` and a `recommendation`.** No exceptions.
   - `rationale` (required) — one or two sentences naming the specific gap, assumption, or contradiction in the plan that triggered this question. The user reads this to know *why you're asking*. Bad: "This is important." Good: "The spec says auto-execute timeout is 120s but never explains why; if real chores routinely take 90s, 120s is too tight a margin."
   - `recommendation` (required) — your pick if forced to answer. For `single`/`yesno`/`scale`: the literal option/number. For `multi`: an array of the options you'd check. For `open`: a one-sentence suggested answer.
   - `recommendationReason` (required) — one sentence on *why* that's your pick. The user reads this to decide whether to accept it or override.

6. **Add a `diagram` to almost every question.** Mermaid source string. Renders between rationale and inputs as a memory palace anchor. Skip only when the question is genuinely too small for visual treatment (binary yes/no with no underlying structure, simple file-path picker). Diagram types to default to:
   - `flowchart LR` / `flowchart TD` — decision branches, routing alternatives
   - `sequenceDiagram` — actor interactions over time
   - `stateDiagram-v2` — lifecycles, failure cascades, modes
   - Optional `diagramCaption` — italic muted line under the figure

7. **Bound it.** Five sharp questions beat fifteen vague ones. 8–15 total.

## Output

Write a self-contained HTML to:

```
~/docs/superpowers/grills/YYYY-MM-DD-<topic>-grill.html
```

Use the shared renderer at `/superpowers/_lib/grill.{css,js}` — do not inline styles.

### Capture the terminal target

```bash
~/.claude/skills/setup-doc-workflow/get-terminal-target.sh
```

Paste the JSON output verbatim into `window.GRILL.target` so the Submit button reaches *this* terminal tab.

### Template

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Grill: <topic></title>
<link rel="stylesheet" href="/superpowers/_lib/grill.css">
<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
<script>
  mermaid.initialize({
    startOnLoad: false,
    theme: "base",
    themeVariables: {
      fontFamily: "-apple-system, SF Pro Display, Helvetica Neue, system-ui, sans-serif",
      primaryColor: "#fbfaf6",
      primaryTextColor: "#1a1a1a",
      primaryBorderColor: "#1a1a1a",
      lineColor: "#1a1a1a",
      secondaryColor: "#f1ede2",
      tertiaryColor: "#ffffff"
    },
    flowchart: { curve: "basis", padding: 12 }
  });
</script>
</head>
<body>

<div class="eyebrow">Plan Grill</div>
<h1><Topic></h1>
<div class="byline">
  <span>YYYY-MM-DD</span>
  <span>Source: <code><plan-filename>.html</code></span>
  <span>N questions</span>
</div>

<p class="ingress">
<2-3 sentences: what does this grill probe for? what's the most uncertain part of the plan?>
</p>

<main id="grill-form"></main>

<script>
window.GRILL = {
  plan: "<plan-filename>.html",
  target: { /* paste output of get-terminal-target.sh */ },
  questions: [
    {
      id: "q1",
      category: "Architecture",
      type: "open",
      text: "...",
      rationale: "Spec says X but never specifies Y; without Y, X is ambiguous when ...",
      diagram: "flowchart LR\n  A[X claim] --> Q{Y?}\n  Q -->|missing| Amb[ambiguous behavior]\n  Q -->|present| Clear[deterministic]",
      recommendation: "...one-sentence suggested answer...",
      recommendationReason: "...why this is the right default..."
    },
    {
      id: "q2",
      category: "Failure modes",
      type: "single",
      text: "...",
      rationale: "Plan handles single-failure case but is silent on streaks; three failures in a row probably means ...",
      diagram: "stateDiagram-v2\n  [*] --> Healthy\n  Healthy --> Strike1: fail\n  Strike1 --> Healthy: success\n  Strike1 --> Strike2: fail\n  Strike2 --> Degraded: fail",
      options: ["A", "B", "C"],
      recommendation: "B",
      recommendationReason: "Avoids burning tokens on a broken delegation path while leaving the fallback in place."
    },
    {
      id: "q3",
      category: "Scope",
      type: "multi",
      text: "...",
      rationale: "...",
      options: ["X", "Y", "Z"],
      recommendation: ["X", "Z"],
      recommendationReason: "X and Z directly affect blast radius; Y is a nice-to-have."
    }
    // ...
  ]
};
</script>
<script src="/superpowers/_lib/grill.js"></script>

</body>
</html>
```

## When the user submits answers

The bridge delivers a message starting with `Grill answers for <plan>:`. Read it, integrate the answers into a revised plan (rewrite the spec HTML accordingly per the user's decisions), then offer:

- Re-grill the revised plan
- Hand off to `writing-plans` skill for implementation
- Build directly via the spec's Build button

## What this skill is not

- **Not a code review.** It questions the *plan*, not the code. If the user wants a code review, hand off to a code-review skill instead.
- **Not a checklist.** Don't generate generic "did you think about X?" questions. Each question must be specific to *this* plan's decisions.
- **Not a vote.** The user's answers are the input; Claude integrates them into a coherent revision, doesn't just append them.
