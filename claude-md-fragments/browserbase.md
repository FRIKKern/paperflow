# BrowserBase

BrowserBase is the cloud parallel + cross-browser visual capture backend used by
`/paperflow:review`'s `visual-investigator` subagent when a single local Chrome DevTools
session is not enough — many pages in parallel, or non-Chrome engines (Firefox, Safari).

Requires a BrowserBase API key (set in the environment as `BROWSERBASE_API_KEY`). The
`visual-investigator` agent picks BrowserBase per the matrix in
`~/.claude/agents/visual-investigator.md`; skills stay backend-agnostic and never name
it directly. Output artifacts land in the same `~/docs/paperflow/captures/<date>-<slug>/`
tree as the other backends, so changelogs render the same regardless of source.
