---
name: pre-flight-capture
description: Use BEFORE any visual UI change — when the spec/plan touches HTML, CSS, JSX, Vue, Svelte, Tailwind, styling, animation, hover, focus, layout, or any user-facing interaction; when the user says "capture before", "the spec touches UI", "before we change visuals"; or when a plan is about to be implemented and includes UI work. Captures pre-flight static screenshots + short videos of the affected interactions, saves them under ~/docs/superpowers/captures/, and returns ready-to-paste markdown/HTML snippets the plan author embeds in a "Pre-flight evidence" section. Same skill is invoked with mode `after` after the build to capture post-flight evidence for the changelog.
---

# pre-flight-capture

Capture visual proof of UI state — *before* any change, then *after*. The captures power the `write-changelog` skill, which renders side-by-side before/after for every visual change.

## When to fire

Trigger phrases:

- "the spec touches UI" / "before we change visuals" / "capture before"
- A plan or spec mentions: `HTML`, `CSS`, `JSX`, `Vue`, `Svelte`, `Tailwind`, styling, animation, hover, focus, layout, transition, color, spacing, typography, component
- A plan is about to be built and at least one file is `.html` / `.css` / `.jsx` / `.tsx` / `.vue` / `.svelte` / `.scss`
- Mode `after`: post-build, to produce the "after" half of the evidence

If unsure whether a change is visual, **ask once**: "This plan looks like it touches the UI — should I run pre-flight capture so the changelog has before/after?"

## Modes

| Mode | When | Filenames |
|---|---|---|
| `before` (default) | Before any code edits land | `before.png`, `before.mp4` (or numbered `before-1.png`…) |
| `after` | After implementation completes, before the changelog | `after.png`, `after.mp4` |

## Process

**Subagent-first.** The main session decides + synthesizes; a visual subagent does the actual capture work.

### 1. Detect surface

| Surface | Signals | Tool |
|---|---|---|
| Web | URL given, dev-server URL, `localhost:*`, `http(s)://`, references to a route/path | `visual-investigator` subagent (Chrome DevTools MCP) |
| Native macOS | `.app`, "the X app", System Settings, Mail/Messages/Finder, AppleScript scope | OpenClaw via `~/.local/bin/openclaw-delegate` for the interaction; `screencapture -v <duration>` for video |
| Ambiguous | Could be either | Ask the user once: "Web (URL?) or native (app name?)" |

### 2. Identify capture targets

For **each interaction the plan changes**, capture both:

- **Static screenshot** of the at-rest state.
- **Short video (3–6 s)** of the interaction (hover, click, focus, animation, transition, layout shift).

If the plan changes 3 components, that's 3 pairs → `before-1.png` + `before-1.mp4`, `before-2.png` + `before-2.mp4`, `before-3.png` + `before-3.mp4`.

If only one target, just `before.png` + `before.mp4`.

### 3. Output path

```
~/docs/superpowers/captures/<YYYY-MM-DD>-<topic-slug>/
```

Same slug as the spec/plan (`2026-05-02-submit-button-redesign` etc). The directory is shared between `before` and `after` so the changelog HTML can reference both via one relative `../captures/.../` path.

### 4. Brief the subagent

#### Web (visual-investigator)

> Navigate to `<url>`. For each of the following targets, capture:
> 1. A static screenshot of the at-rest state.
> 2. A 4-second screen recording (mp4) of the interaction described.
>
> Targets:
> - **Submit button at-rest**: screenshot only.
> - **Submit button hover**: record 4 s while you move the cursor onto the button and hold.
> - **Form focus state**: record 4 s clicking into the email input.
>
> Save into `~/docs/superpowers/captures/2026-05-02-submit-button-redesign/` as `before.png`, `before-hover.mp4`, `before-focus.mp4`.
>
> Return only the file paths, one per line. No summary.

#### Native (OpenClaw + screencapture)

For native interactions, two-step:

```bash
# Start video capture (5s, mouse cursor included, no sound)
screencapture -v -V 5 -C ~/docs/superpowers/captures/<dir>/before.mp4 &

# Trigger the interaction via OpenClaw
~/.local/bin/openclaw-delegate --message "Open <app>, click the <thing>" --json --timeout 30

wait  # let screencapture finish
```

For static-only:

```bash
screencapture -x ~/docs/superpowers/captures/<dir>/before.png
```

### 5. Return to the main session

A markdown/HTML snippet block ready to paste into the plan's "Pre-flight evidence" H2:

```html
<h2>Pre-flight evidence</h2>

<figure>
  <img src="../captures/2026-05-02-submit-button-redesign/before.png" alt="Submit button at-rest">
  <figcaption>Before: at-rest state — heavy 2px border, off-brand red.</figcaption>
</figure>

<figure>
  <video src="../captures/2026-05-02-submit-button-redesign/before-hover.mp4"
         autoplay loop muted playsinline></video>
  <figcaption>Before: hover state (jarring color shift, 0ms transition).</figcaption>
</figure>
```

Plus a one-line summary the main session can echo: *"3 captures saved to `captures/2026-05-02-submit-button-redesign/`. Embedded in the plan's Pre-flight evidence section."*

## After-mode

Same skill, invoked with `mode: after`. Same target directory, same target list (read from the `before-*` filenames already there). Output `after.png` / `after-*.mp4`. Return the same kind of HTML snippet — `write-changelog` consumes both `before-*` and `after-*` files from the directory and renders the side-by-side evidence.

## Embedding in plans

Plan templates get one new H2 near the top:

```html
<h2>Pre-flight evidence</h2>
<!-- pre-flight-capture skill drops figures here -->
```

The skill produces the `<figure>` blocks. Plan author pastes them in. That's it — no template surgery.

## What this skill is not

- **Not a custom CLI capture tool.** Use existing subagents (`visual-investigator` for web, OpenClaw for native).
- **Not a video editor.** 3–6 second clips, autoplay-loop-muted. No transitions, no compositing.
- **Not a screenshot diff tool.** It captures; the changelog HTML displays.
- **Not BrowserBase.** Local only. Defer cloud capture until needed.
