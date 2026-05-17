# Paperflow

Turn a one-line Goal into a planned, grilled, built, and reviewed change — with HTML you can read at every step.

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/paperflow/main/scripts/quickstart.sh | bash
```

---

## First five minutes

1. **Install** with the curl line above. About a minute. Idempotent — re-run any time to upgrade. Hard-fails if a service ends up unhealthy, so you never get a half-broken state.
2. **Restart Claude Code** (or run `/hooks` in any already-open session) so the new hooks, skills, and `CLAUDE.md` get picked up.
3. In any project, type `/paperflow:goal "rewrite the onboarding flow"`. paperflow opens a Goal HTML in your browser, sets up Beads in the repo, drops you back at the prompt.
4. From there, `/paperflow:plan` to draft and grill a plan, or `/paperflow:autopilot` if you want it to chain plan → grill → build → review in one push (it pauses at the grill so you stay in the loop).
5. Every artifact opens automatically at `http://localhost:8767/paperflow/...`. Click "Build this plan" inside the doc — the prompt lands in the terminal where Claude is running.

There's also a `pf` CLI for kicking flows off without opening Claude Code first: `pf goal "ship auth"`, `pf autopilot "fix typecheck"`, `pf doctor`, `pf status`. `pf goal` spawns a fresh Claude in the current directory via cmux and sends the slash command for you.

---

## What you actually do

Four verbs, in order. **Open a Goal.** That's a vision sentence and three default phases (pre-flight, build, review). **Plan it.** A subagent drafts an HTML plan, grills it with 8–15 pointed questions, revises with you, then materialises the steps as Beads work-tasks. **Build it.** The orchestrator claims the next ready task, dispatches a focused subagent, verifies the result, closes the task, repeats until the phase empties. **Review it.** A reviewer subagent checks the work; rejection re-opens the same build-task on `branch:main`, no orphan branches.

Everything else — questionnaires when shape is unclear, simplify passes, changelogs with before/after screenshots — is a sub-action inside one of those four.

---

## What it looks like

<!-- TODO: insert ~10s loop GIF + 2 screenshots (rail, dock) -->

Specs, plans, and grills open as HTML articles in your browser at `localhost:8767` — serif body, captioned figures, Mermaid diagrams throughout. A 240 px sticky right rail shows the active Goal's lifecycle as a clickable git-graph; click an older event to walk back, shift-click two nodes for a line-level diff. Under cmux, four live feeds stream into the right-side Dock: active Goal/Phase/Task, ready tasks, recent events, the auto-open log. Action buttons inside each doc — Build this plan, Grill the spec, Submit, Simplify — POST back to the bridge, which routes the message into the terminal where Claude is running.

The statusline shows the active Goal and Phase at a glance:

```
137,420 / 1M · 1209d022 · onboarding-revamp · ▸ phase 2/3: build · ▸ paperflow-a1b2.2.3 wire-bridge · 4/9 · main
```

Files you'll touch:

```
~/docs/paperflow/specs/<date>-<slug>.html        # specs
~/docs/paperflow/plans/<date>-<slug>.html        # plans
~/docs/paperflow/grills/<date>-<slug>.html       # grill stress-tests
~/docs/paperflow/goals/<slug>/index.html         # the Goal's HTML home
~/docs/paperflow/changelog/<date>-<topic>.html   # before/after proof pages
<repo>/.paperflow/{active-goal,active-phase}     # the entire mutable state
```

A typical session in your terminal:

```
> /paperflow:goal "rewrite onboarding"
✓ Goal opened: paperflow-a1b2 (onboarding-revamp)
  → ~/docs/paperflow/goals/onboarding-revamp/index.html

> /paperflow:plan
  draft → grill (12 questions) → revise
  ✓ 9 work-tasks materialised under phase-build

> /paperflow:build
  ✓ paperflow-a1b2.2.1 closed (subagent: 47 LOC, verified)
  ✓ paperflow-a1b2.2.2 closed (subagent: 22 LOC, verified)
  …
```

---

## Why it exists

Most Claude Code workflows let the model decide what's important and trust it to remember. That breaks at scale — context drifts, plans go half-finished, half the work happens inside one giant orchestrator turn that nobody can audit afterwards. paperflow inverts that. Every meaningful step writes an HTML doc you can read, click through, and reject. The orchestrator stays in coordination; subagents do the focused work. Specs and plans aren't disposable side-effects — they're the artifact, and the right rail keeps their full history one click away.

The loop:

```mermaid
flowchart LR
    G["/paperflow:goal"]
    Q["questionnaire<br/>(when useful)"]
    P["/paperflow:plan<br/>draft → grill → revise"]
    B["/paperflow:build<br/>claim → dispatch →<br/>verify → close"]
    R["/paperflow:review"]
    Done(["Goal done"])

    G --> Q --> P --> B --> R
    G -->|"trivial shape"| P
    R -->|"approved"| Done
    R -->|"rejected"| B
```

Rejection re-opens the build-task on the same `branch:main`. The orchestrator is one Claude Code instance; every non-trivial step is delegated to a subagent (hard 30 LOC / 50 line / 500 token thresholds, audited by `Subagent-Run:` commit trailers in `/paperflow:review`).

---

## Reference: the slash commands

Eight skills, total. The cap is enforced by `scripts/check-skill-count.sh` — a ninth needs to displace one of these.

| Skill | What it does | Trigger phrases |
|---|---|---|
| `/paperflow:goal` | Opens, snapshots, or archives a Goal — creates the goal-task, three default phases, both pointer files, renders the Goal HTML. | "start a goal", "snapshot the goal", "archive the goal" |
| `/paperflow:plan` | Drafts a plan, grills it with 8–15 pointed questions, revises; materialises plan steps as Beads work-tasks. Simplify is a sub-action here. | "plan X", "grill this plan", "simplify this doc" |
| `/paperflow:build` | Claims the next ready task, dispatches a subagent, verifies on return, closes; loops the phase, advances when empty. | "build", "next step", "ship it", "next phase" |
| `/paperflow:review` | Opens a review-task linked to a build-task; delegates the review (or site audit) to a subagent. Includes a Subagent-Run audit. | "request review", "review this PR", "audit my site" |
| `/paperflow:install` | The meta-skill — install, upgrade, reset, integration opt-in, author a new SKILL.md, write release changelogs. | "install paperflow", "upgrade paperflow", "what is paperflow?" |
| `/paperflow:resume` | Mirrors Claude Code's `/resume` for Goals. Lists Goals via Beads, presents a numbered menu, flips the two pointers on pick. | "/resume", "list goals", "switch to goal X" |
| `/paperflow:setup` | First-run host install — runs `install.sh` after `/plugin install paperflow`. Re-run with `--upgrade` or `--reset`. | "/paperflow:setup" after a fresh plugin install |
| `/paperflow:autopilot` | Chains `goal → plan → grill → build → review` in one push. Pauses MANDATORY at the grill (unless `--skip-grill`). Stops one click short of archive. | "autopilot", "run on autopilot", "do the whole flow" |

---

## Prerequisites and other install paths

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![macOS only](https://img.shields.io/badge/macOS-only-blue)
![Node 22+](https://img.shields.io/badge/node-22%2B-green)
![8 skills](https://img.shields.io/badge/skills-8%20max-orange)
![cmux-first](https://img.shields.io/badge/cmux-first-purple)
![GitHub stars](https://img.shields.io/github/stars/FRIKKern/paperflow)

- macOS only. Linux is an explicit non-goal — `paperflow-target` and the cmux integration are mac-specific.
- [Homebrew](https://brew.sh) — used to auto-install `jq` and `beads` if missing.
- Node 22+ (`brew install node` or `brew install nvm && nvm install 22`).
- Any modern terminal — cmux is best (paperflow's Dock and tab-reuse contracts target it).

**As a Claude Code plugin:**

```
/plugin marketplace add https://github.com/FRIKKern/paperflow
/plugin install paperflow
/paperflow:setup
```

The first two are stock Claude Code commands. The third runs the bundled `install.sh` after explaining what it touches and asking for consent — single host-scoped daemon on :8767, the cmux dock daemon, statusline, `~/.claude/CLAUDE.md`, `~/.local/bin/` shims, optional brew installs.

**Read first, then run:**

```bash
git clone https://github.com/FRIKKern/paperflow.git ~/Documents/GitHub/paperflow
bash ~/Documents/GitHub/paperflow/install.sh
```

Full install detail, optional `--with-*` flags, manual install, and uninstall in [INSTALL.md](INSTALL.md).

---

## Troubleshoot

**`brew not found`** — Install brew first at https://brew.sh, then re-run the quickstart. macOS-only.

**Bridge port 8766 unreachable** — `lsof -i :8766` for a stale process; kill it and re-run install. Only one paperflow bridge can listen on 8766 at a time.

**Daemon port 8767 unreachable** — same idea: `lsof -i :8767`. Most often a dev server is squatting on the port. Kill it or override the daemon port in the LaunchAgent plist.

**npm EACCES on global install** — the installer is nvm-aware. If your `node` is from nvm you'll skip the EACCES branch. If it's a system install: `sudo chown -R $(whoami) /usr/local/{lib/node_modules,bin,share}`.

**CLAUDE.md exists, but I want the new `--with-X` fragments** — re-run with `--merge --with-openclaw` (or whichever flag). Each fragment has a sentinel comment, so re-merging is safe.

**Hooks duplicated in `settings.json`** — fixed in 2026-05-07: hook dedup uses exact-path match. For older duplicates, edit `~/.claude/settings.json` and remove the duplicate `command` entries under `hooks.PostToolUse[].hooks[]`.

**cmux trust broken-pipe on browser button clicks** — the bridge needs to inherit cmux's socket auth. Respawn from inside a cmux pane: `cmux new-workspace --command "node ~/.local/lib/paperflow/claude-bridge.js"`.

**Statusline empty in a Goal-active repo** — cache stale and live composition failed. Run any Beads-mutating action (claim/close); cache rewrites.

**Goal-path rail empty on a fresh doc** — doc didn't set `window.PAPERFLOW_GOAL_ID`. Add the inline script before the `doc.js` include.

**Beads not found (`bd: command not found`)** — the quickstart auto-installs Beads via Homebrew; if that failed silently: `brew install beads` or `npm i -g beads`. Re-run `bash install.sh` afterwards.

**Dock daemon dead** — `cat ~/.paperflow/dock-daemon.pid` (0 bytes if down). Restart with `bash install.sh`; inspect `tail /tmp/paperflow-dock-daemon.log` for the cause.

### Logs

```
~/.local/log/docs-livereload.{out,err}.log
~/.local/log/claude-bridge.{out,err}.log
/tmp/paperflow-dock-daemon.log               # non-cmux stderr
~/.paperflow/auto-open.log                   # auto-open events (rotates at 1 MB)
~/.paperflow/simplify-failures.log           # rejected Simplify candidates
~/.paperflow/questionnaire-skips.log         # skipped questionnaires
```

---

## Architecture and internals

The bridge HTTP endpoints, hook composition, statusline internals, dock daemon, simplify pipeline, subagent thresholds, doc authoring conventions, and repo layout all live in [ARCHITECTURE.md](ARCHITECTURE.md). Read that if you're hacking on paperflow itself.

---

## License

MIT — see [LICENSE](./LICENSE).

paperflow draws on patterns from [`obra/superpowers`](https://github.com/obra/superpowers) (MIT) — `/paperflow:plan` adapts `writing-plans` and `brainstorming`; `/paperflow:build` adapts `executing-plans`, `verification-before-completion`, `subagent-driven-development`, `dispatching-parallel-agents`, `using-git-worktrees`, `systematic-debugging`; `/paperflow:review` adapts `requesting-code-review`, `receiving-code-review`, `finishing-a-development-branch`. Where a section is structurally identical to an upstream skill, an inline note in the SKILL.md points back to [THIRD-PARTY-CREDITS.md](./THIRD-PARTY-CREDITS.md).

paperflow uses [Beads](https://github.com/gastownhall/beads) (MIT) as the system of record. Beads is invoked as a runtime dependency — paperflow does not bundle, redistribute, or modify it.
