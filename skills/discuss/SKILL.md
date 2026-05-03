---
name: discuss
description: Use when the user asks to discuss / explain in depth / compare / deep-dive / weigh / brainstorm a topic, OR when your reply would otherwise be a long terminal answer (>300 words, multiple diagrams, multiple tables, architecture or trade-off discussion). Writes the discussion to a beautiful HTML article at ~/docs/superpowers/notes/, auto-opens it in the browser, and includes a reply textarea at the bottom so the user can send back a structured response. Keeps chat reply terse (1-3 sentence summary + URL).
---

# discuss

Turn long-form discussions into HTML articles instead of terminal walls of text. Same article-style typography as specs / plans / grills (ingress, brødtekst, captioned figures, serif body, sans headings). Distribute Mermaid diagrams throughout — at least one visual every ~300 words.

## When to fire

| Use this skill when | Reply inline when |
|---|---|
| User asks: "discuss" / "explain in depth" / "compare" / "deep-dive" / "weigh options" / "brainstorm" | Single-question Q&A |
| Your response would be > 300 words | Status / "done" / "fixed" |
| Response has 2+ Mermaid diagrams or 3+ tables | Code fix or single-line answer |
| Architecture / trade-off / decision discussion | "Run this command" |
| The previous turn went here too (continuation) | Yes/no answer |

If unsure, lean toward the article. Brevity wins in chat; depth wins on page.

## Process

1. **Capture the terminal target:**

   ```bash
   ~/.local/bin/paperflow-target
   ```

   Save the JSON output — paste it verbatim into `window.CLAUDE_TARGET` in the generated HTML.

2. **Pick a slug.** `YYYY-MM-DD-<short-topic-slug>.html`. Today's date in `YYYY-MM-DD` form. Short, kebab-case slug capturing the topic in 2–4 words.

3. **Spawn a subagent to write the article.** Per paperflow's subagent-first principle, the main session decides + synthesizes; the subagent does the long-form writing. Brief the subagent (subagent_type: `general-purpose`) with:
   - The topic and the conclusion / framing the user is interested in
   - The output path (below)
   - The full HTML template structure (eyebrow, title, byline, ingress, body sections with Mermaid figures + tables, optional pullquote, bottom-line)
   - The exact `<script>` tail with `window.CLAUDE_TARGET`, `window.DOC_PATH`, and `<script src="/superpowers/_lib/doc.js">`
   - "Write the article body. Return the URL when done. Do not summarize the content."

4. **Write the article** to:

   ```
   ~/docs/superpowers/notes/<slug>.html
   ```

   Article structure:
   - **Eyebrow** — `Note · <category>` (e.g. "Discussion", "Comparison", "Deep dive")
   - **H1 title** — sharp, descriptive
   - **Byline** — date · topic · main conclusion (one phrase)
   - **Ingress** — bolded lead paragraph (2–3 sentences) summarizing what the article concludes / explores
   - **Body sections** — H2 headings, prose + tables + figures. Each major decision or comparison gets a Mermaid diagram. Aim for 1 visual per ~300 words.
   - Optional **pullquote** for a sharp insight worth amplifying
   - **Bottom-line** section if there's a recommendation

4. **End the body with this exact tail** (the auto-open hook fires on Write):

   ```html
   <script>
     window.CLAUDE_TARGET = /* JSON from paperflow-target */;
     window.DOC_PATH = "<slug>.html";
   </script>
   <script src="/superpowers/_lib/doc.js"></script>
   ```

   `doc.js` will inject a **Reply** textarea + button (and a **Make this a spec** secondary) at the bottom.

5. **When the subagent returns**, reply in chat tersely — 1 to 3 sentences max + the localhost URL:

   ```
   Wrote the discussion to http://localhost:8765/superpowers/notes/<slug>.html.
   <one-sentence summary of the conclusion or framing>.
   ```

   Don't restate the article in chat. The user will read it in browser.

## Template

Use the same article CSS as specs/plans (inline `<style>` block, Mermaid 10 from CDN). For consistency, copy the head + style from `~/docs/superpowers/notes/2026-05-03-skills-vs-infrastructure.html` (the canonical example) and adapt the body.

Minimal head:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Note: <topic></title>
<style>/* same article-style CSS as specs */</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
<script>
  mermaid.initialize({
    startOnLoad: true, theme: "base",
    themeVariables: {
      fontFamily: "-apple-system, SF Pro Display, Helvetica Neue, system-ui, sans-serif",
      primaryColor: "#fbfaf6", primaryTextColor: "#1a1a1a",
      primaryBorderColor: "#1a1a1a", lineColor: "#1a1a1a",
      secondaryColor: "#f1ede2", tertiaryColor: "#ffffff"
    },
    flowchart: { curve: "basis", padding: 16 }
  });
</script>
</head>
```

## After the user clicks Reply

The bridge delivers a message starting with `Re: <slug>.html: <user's reply text>`. Read the reply in the context of the original note, decide if the response warrants:

- Another `discuss` note (continuation)
- A direct chat reply (short)
- Promotion to a `/specs/` artifact (if the user clicked **Make this a spec**)

## Final review (mandatory)

Before returning the URL to the user, invoke the `paperflow-review-doc` skill on the artifact path. If it returns `ok: false`, fix the offending blocks (typically Mermaid syntax errors) and re-save. Iterate up to 3 times. If still failing after 3 iterations, return the URL with a clear note that some Mermaid blocks may not render correctly — don't pretend it shipped clean.

## Don't

- Don't write a discuss note for a yes/no answer or a code fix.
- Don't paraphrase the article in chat after writing it. Brief summary + URL only.
- Don't skip the diagrams — if a topic is worth a discuss note, it has visual structure. Find it.
- Don't omit the `<script>` tail — without it, the Reply button won't appear.
