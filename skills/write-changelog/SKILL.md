---
name: write-changelog
description: Use AFTER implementing a UI change to generate the proof page — an HTML article at ~/docs/superpowers/changelog/ that puts before/after captures side-by-side, names the files touched, lists what was verified, and gives a one-line rollback. Triggered by phrases like "write the changelog", "publish the proof", or automatically after a build that pre-flight-capture was run for. Consumes captures from ~/docs/superpowers/captures/<same-slug>/ (both `before-*` and `after-*` files).
---

# write-changelog

After a UI change ships, write a one-page proof: before / after, what changed, files touched, how it was verified, how to roll back. Same article-style typography as specs and plans.

## When to fire

- "write the changelog" / "publish the changelog" / "make the proof page"
- A build just completed and `pre-flight-capture` produced `before-*` files; the implementing agent now has `after-*` files in the same `captures/` directory
- A spec or plan that ran through `pre-flight-capture` reaches "Done"

If pre-flight evidence exists but post-flight doesn't, **first** invoke `pre-flight-capture` with `mode: after` to fill in the missing half.

## Inputs

1. The captures directory: `~/docs/superpowers/captures/<YYYY-MM-DD>-<topic-slug>/`
2. The plan or spec the change came from (for cross-linking)
3. Git diff or list of files touched

## Output

```
~/docs/superpowers/changelog/<YYYY-MM-DD>-<topic-slug>-changelog.html
```

URL: `http://localhost:8765/superpowers/changelog/<filename>.html`

The auto-open hook fires on Write of this path. `doc.js` detects `/changelog/` in the URL and renders a "Share" action button.

## Process

**Subagent-first.** Main session decides scope; subagent writes the long-form HTML. Brief:

> Read these inputs:
> - Captures directory: `<path>` (list `before-*` and `after-*` files, pair them by suffix)
> - Source plan: `<plan-filename>.html`
> - Files touched + summary diff: `<inline list>`
>
> Write a self-contained HTML changelog to `<output-path>` using the template in the `write-changelog` SKILL.md. Pair every `before-*` with its matching `after-*` (e.g., `before-hover.mp4` ↔ `after-hover.mp4`). Article-style typography — same eyebrow/title/byline/ingress/H2 pattern as the spec template. End with `window.CLAUDE_TARGET`, `window.DOC_PATH`, and `<script src="/superpowers/_lib/doc.js">`. Capture the terminal target via `~/.local/bin/paperflow-target`.
>
> Return only the URL.

## Sections (in order)

1. **Eyebrow + title + byline + ingress** — same pattern as specs/plans. Eyebrow: `Changelog`. Byline: date · source plan · files-touched count.
2. **Hero: before vs after side-by-side.** For each capture pair, two figures in a flex row: `before.mp4` / `after.mp4` (or `.png` if no video). Both videos `autoplay loop muted playsinline`. Caption each side. Caption the pair.
3. **What changed** — 1–3 short paragraphs in user-facing terms. *"Hover now fades through brand-tinted opacity over 200 ms instead of snapping to red."* Not the diff. The *experience*.
4. **Files touched** — small table: `path` · `summary of edit`.
5. **Verification** — checklist of what was tested (which browsers, which interactions, which viewport widths if relevant).
6. **Reverting** — one-line rollback command if applicable. *"`git revert <sha>` — single commit, no migration."*
7. **Action bar** (auto-injected by `doc.js` because URL contains `/changelog/`): one Share button.

## Template

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Changelog: <topic></title>
<link rel="stylesheet" href="/superpowers/_lib/doc.css">
<style>
  /* Reuse spec/plan tokens. doc.css ships them. */
  .changelog-hero {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1rem;
    margin: 2rem 0 2.4rem;
  }
  .changelog-hero figure { margin: 0; }
  .changelog-hero img,
  .changelog-hero video {
    width: 100%;
    height: auto;
    border-radius: 6px;
    border: 1px solid var(--rule, #e6e2d8);
    background: #000;
    display: block;
  }
  .changelog-hero figcaption {
    font-family: var(--sans, system-ui);
    font-size: .85rem;
    color: var(--muted, #6a6a6a);
    margin-top: .5rem;
    font-style: italic;
  }
  .changelog-pair-caption {
    font-family: var(--sans, system-ui);
    font-size: .82rem;
    color: var(--muted, #6a6a6a);
    text-align: center;
    margin: -.8rem 0 2rem;
  }
  .files-table {
    width: 100%;
    border-collapse: collapse;
    font-size: .92rem;
    margin: 1rem 0 2rem;
  }
  .files-table th, .files-table td {
    text-align: left;
    padding: .55rem .8rem;
    border-bottom: 1px solid var(--rule, #e6e2d8);
    vertical-align: top;
  }
  .files-table th {
    font-family: var(--sans, system-ui);
    font-size: .78rem;
    text-transform: uppercase;
    letter-spacing: .08em;
    color: var(--muted, #6a6a6a);
    font-weight: 600;
  }
  .files-table code {
    font-family: var(--mono, ui-monospace);
    font-size: .85rem;
  }
  .verify-list { padding-left: 1.2rem; }
  .verify-list li { margin: .35rem 0; }
  .revert-cmd {
    font-family: var(--mono, ui-monospace);
    background: var(--code-bg, #f1ede2);
    padding: .8rem 1rem;
    border-radius: 4px;
    font-size: .92rem;
  }
</style>
</head>
<body>

<div class="eyebrow">Changelog</div>
<h1><Topic — what shipped></h1>
<div class="byline">
  <span>YYYY-MM-DD</span>
  <span>Source: <code><plan-filename>.html</code></span>
  <span><N> files touched</span>
</div>

<p class="ingress">
<2–3 sentences: what shipped, in user-facing terms. Not "we changed X to Y" — "the Submit button now feels less aggressive, the hover settles instead of snapping."
</p>

<!-- One pair per before/after match. Pair video<->video, image<->image. -->
<div class="changelog-hero">
  <figure>
    <video src="../captures/<dir>/before-hover.mp4" autoplay loop muted playsinline></video>
    <figcaption>Before — hover state</figcaption>
  </figure>
  <figure>
    <video src="../captures/<dir>/after-hover.mp4" autoplay loop muted playsinline></video>
    <figcaption>After — hover state</figcaption>
  </figure>
</div>
<p class="changelog-pair-caption">Submit button hover: jarring red flash → 200 ms fade through brand tint.</p>

<!-- Repeat .changelog-hero block for each capture pair -->

<h2>What changed</h2>
<p>1–3 short paragraphs in user-facing terms.</p>

<h2>Files touched</h2>
<table class="files-table">
  <thead>
    <tr><th>Path</th><th>Summary</th></tr>
  </thead>
  <tbody>
    <tr><td><code>src/components/SubmitButton.tsx</code></td><td>Replaced abrupt color swap with 200 ms opacity transition.</td></tr>
    <tr><td><code>src/styles/buttons.css</code></td><td>New <code>--btn-hover-fade</code> token.</td></tr>
  </tbody>
</table>

<h2>Verification</h2>
<ul class="verify-list">
  <li>Chrome 130, Safari 18, Firefox 130 — desktop</li>
  <li>Hover, focus, active states all checked</li>
  <li>Reduced-motion preference honored (no transition when set)</li>
  <li>Lighthouse a11y unchanged (98)</li>
</ul>

<h2>Reverting</h2>
<div class="revert-cmd">git revert &lt;sha&gt; — single commit, no migration</div>

<script>
  window.CLAUDE_TARGET = /* paste output of paperflow-target */;
  window.DOC_PATH = "<this-filename>.html";
</script>
<script src="/superpowers/_lib/doc.js"></script>

</body>
</html>
```

## Pairing rule

For each `before-<suffix>.{png,mp4}` in the captures directory, find the matching `after-<suffix>.{png,mp4}`. If a `before-*` has no `after-*` partner: warn in the changelog ("post-flight capture missing for hover") rather than silently dropping. If an `after-*` has no `before-*`: include it solo as "New".

## Capture the terminal target

```bash
~/.local/bin/paperflow-target
```

Paste the JSON into `window.CLAUDE_TARGET` so the Share button reaches *this* terminal tab.

## Final review (mandatory)

Before returning the URL to the user, invoke the `paperflow-review-doc` skill on the changelog HTML path. If it returns `ok: false`, fix the offending blocks (typically Mermaid syntax errors) and re-save. Iterate up to 3 times. If still failing after 3 iterations, return the URL with a clear note that some Mermaid blocks may not render correctly — don't pretend it shipped clean.

## What this skill is not

- **Not a release-notes generator.** Single change set, single page. No version numbers.
- **Not a code review.** Files-touched is a summary, not a diff dump.
- **Not regenerated retroactively.** One changelog per shipped change. If something else ships later, write a new changelog.
