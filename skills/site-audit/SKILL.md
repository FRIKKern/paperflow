---
name: site-audit
description: Use when the user asks to audit a whole site, run lighthouse on every page, do an SEO check, get thumbnails of every page, or get a site overview. Trigger phrases include "audit my site", "lighthouse on X", "SEO check", "show me every page", "thumbnails of every page", "site overview". Runs `~/.local/bin/paperflow-audit-site --site <url>` (Unlighthouse wrapper), surfaces the resulting `<dir>/index.html` report. The wrapper handles auto-open via `open`. For auth-gated sites, supports cookie injection or Playwright storage state. For retries, supports `--resume <slug>` reading from `~/.openclaw/logs/audit-failures.jsonl`.
---

# site-audit

Whole-site audit: Lighthouse scores per page, SEO checks, performance, accessibility, and screenshot thumbnails of every URL. One run produces a navigable site map. The work is delegated to the `visual-investigator` agent which routes "site" surfaces to Unlighthouse via the `paperflow-audit-site` wrapper.

## When to fire

Trigger phrases:

- "audit my site" / "audit X"
- "lighthouse on X" / "run lighthouse"
- "SEO check" / "SEO audit"
- "show me every page" / "thumbnails of every page"
- "site overview" / "site map with screenshots"
- "what does my site look like" (when target is a whole site, not a single page)

Disambiguator: if the request names a single URL/route ("how does the pricing page look?"), this is a single-page job — fall through to `pre-flight-capture` / `visual-investigator` instead.

## Process

### 1. Confirm the target

Ask once if ambiguous: "Audit which site? (URL — full origin, e.g. `https://paperflow.dev` or `http://localhost:8765`.)"

### 2. Brief the visual-investigator agent

Spawn the `visual-investigator` agent (subagent_type: `general-purpose`, or wherever it's wired in your harness) with a brief shaped:

```
{
  surface: "site",
  target: "<url>",
  captures_needed: ["full-site Lighthouse audit + thumbnails"]
}
```

The agent picks Unlighthouse from its selection rule and runs:

```bash
~/.local/bin/paperflow-audit-site --site <url> [--slug <slug>]
```

The wrapper auto-runs `open <dir>/index.html` on success.

### 3. Surface the result

Report back: the report path (`~/docs/paperflow/audits/<date>-<slug>/index.html`), the live URL (`http://localhost:8765/paperflow/audits/<date>-<slug>/index.html` if the user wants to share), and a 1-line summary of what was captured.

### 4. Pre-req fallback

If the wrapper exits non-zero with the `unlighthouse not found` install hint, surface it verbatim:

```
npm install -g @unlighthouse/cli puppeteer
```

Don't auto-install — user opts in.

### 5. Partial-failure / resume

If the wrapper exits non-zero mid-crawl, it writes `failure.log` to the audit dir and appends a JSONL record to `~/.openclaw/logs/audit-failures.jsonl`. Surface the partial-report path and offer:

```bash
~/.local/bin/paperflow-audit-site --resume <slug>
```

## Auth-gating recipes

Two paths cover the realistic auth space without hand-rolling SSO:

### Cookie injection (simple session)

For sites that just need a session cookie, write a JSON file shaped like:

```json
[
  {"name": "session", "value": "abc123", "domain": ".example.com", "path": "/"},
  {"name": "csrf",    "value": "xyz789", "domain": ".example.com", "path": "/"}
]
```

Then construct an Unlighthouse config that injects them via a page-handler hook. Unlighthouse reads `unlighthouse.config.ts` from the working dir; minimal example:

```ts
// unlighthouse.config.ts
import cookies from "./cookies.json"

export default {
  hooks: {
    "puppeteer:before-goto": async (page) => {
      await page.setCookie(...cookies)
    }
  }
}
```

Then run the wrapper from that working dir.

### Playwright storage state (richer auth flow)

For sites that need a real login, capture a Playwright storage state once:

```bash
# one-time, per credential set
playwright codegen <site>
# (log in interactively in the codegen window; save storage state)
```

Save to `~/.paperflow/states/<site>.json`. Then:

```ts
// unlighthouse.config.ts
import { chromium } from "playwright"
import storage from "/Users/<you>/.paperflow/states/<site>.json"

export default {
  puppeteerClusterOptions: {
    puppeteer: chromium,
    puppeteerOptions: { storageState: storage }
  }
}
```

SSO flows that involve federated identity (Okta, Azure AD, Google) are explicitly out of scope. Storage state typically covers them anyway because the post-SSO session cookie gets saved, but the wrapper makes no promises and will fail the audit if the IdP redirects mid-crawl.

## What this skill is not

- **Not single-page capture.** Use `pre-flight-capture` / `visual-investigator` for that.
- **Not a substitute for production monitoring.** Unlighthouse is for ad-hoc audits, not continuous synthetic monitoring.
- **Not BrowserBase.** Local Puppeteer through Unlighthouse; no cloud sessions.
