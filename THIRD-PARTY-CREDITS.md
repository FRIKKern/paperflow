# Third-Party Credits

paperflow draws on patterns and structural ideas from the following projects.

## Superpowers (`obra/superpowers`)

paperflow's `paperflow-plan`, `paperflow-build`, and `paperflow-review` skills incorporate structural patterns from the Superpowers project (https://github.com/obra/superpowers), licensed MIT. Specifically:

- Plan-execution loop in `paperflow-build` adapts patterns from `executing-plans`, `verification-before-completion`, `subagent-driven-development`, `dispatching-parallel-agents`, and `systematic-debugging`.
- Plan-writing in `paperflow-plan` adapts patterns from `writing-plans` and `brainstorming`.
- Code-review structure in `paperflow-review` adapts patterns from `requesting-code-review`, `receiving-code-review`, and `finishing-a-development-branch`.
- The skill-writing meta-pattern in `paperflow-install` adapts `writing-skills`.
- The entry-point document in `paperflow-install` evolves from `using-superpowers`.

Where a `SKILL.md` section is structurally identical to an upstream skill (same headings, same prompts), an inline note appears at the top of that section pointing back here.

### MIT License (Superpowers)

Copyright (c) 2025 Jesse Vincent

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Beads (`steveyegge/beads`)

paperflow uses Beads (`bd`) as the system of record for goals, phases, and tasks. Beads is licensed MIT. paperflow does not bundle, redistribute, or modify Beads — it invokes the `bd` CLI as a runtime dependency.

The Beads upstream and full license: https://github.com/gastownhall/beads (or whichever the brew-resolvable canonical is — defer to whichever the install.sh hint points at).
