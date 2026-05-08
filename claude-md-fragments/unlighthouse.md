# Unlighthouse

Unlighthouse powers paperflow's whole-site audit sub-flow inside `/paperflow:review`.
It crawls every page on a site and returns a Lighthouse report per URL — performance,
SEO, accessibility, best-practices.

Install (opt-in, ~50 MB):

    npm install -g @unlighthouse/cli puppeteer

Trigger phrases that fire the site-audit sub-flow inside `/paperflow:review`:
"audit my site", "lighthouse on X", "SEO check", "show me every page", "site overview".
Output lands at `~/docs/paperflow/audits/<date>-<slug>/index.html` via the
`~/.local/bin/paperflow-audit-site` wrapper. The `visual-investigator` subagent picks
Unlighthouse per the matrix in `~/.claude/agents/visual-investigator.md`.
