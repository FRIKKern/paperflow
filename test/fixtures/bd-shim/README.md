# bd-shim fidelity fixtures (w7-08 / Gate-B)

Golden JSON shapes captured from real `bd` against
`~/Documents/github/paperflow/.beads`. The contract: for each fixture,
the bd-shim's equivalent invocation against a seeded Barkpark instance
must produce JSON whose **shape** (sorted top-level key set + per-key
value type) matches the golden's shape. Driver: `test/bd-shim-fidelity.sh`.

## Why shape-equality, not byte-equality

The captured fixtures freeze REAL doc_ids (`paperflow-7r9`) and REAL
timestamps. The seeded Barkpark has different ids + timestamps. Byte
equality would require freezing every upstream value — brittle, and the
fidelity gate isn't about specific data, it's about the *consumer-facing
JSON contract*. Adding/dropping a key, flipping a type from string→number,
or omitting a documented field breaks consumers; shape-diffing catches
exactly those.

## Seed mechanism (deferred)

The fidelity script's preflight requires a live Barkpark at `$BARKPARK_URL`
(default `http://localhost:4001`). Without seeded data, `bd ready --json`
returns `[]` (technically shape-equal to an empty captured fixture, but
the per-id `bd show paperflow-7r9 --json` runs return `not found`).

Two seed paths considered:

  1. **`seed.sql`** — direct INSERT statements into the barkpark DB.
     Cheapest to author, but couples the fidelity harness to the
     `documents` table schema (column drift breaks the seed).

  2. **`import-beads.sh`** — read `.beads/issues.jsonl` and POST each
     entry through `Content.create_document/4`. Goes through the
     validators we're exercising. More work today; portable forever.

**Choice: option (2), deferred to a follow-up task.** The harness is
runnable today against a hand-seeded barkpark — useful for spot-checks
during shim development. The full reproducible seeder ships next.

## Fixture catalog

| Fixture                              | bd invocation                                                                     |
|--------------------------------------|-----------------------------------------------------------------------------------|
| `ready-all.json`                     | `bd ready --json`                                                                 |
| `ready-phase-build.json`             | `bd ready --label phase-build --json`                                             |
| `ready-phase-and-goal.json`          | `bd ready --label phase-build --label goal-w7-retire-beads --json`                |
| `list-all.json`                      | `bd list --json`                                                                  |
| `list-type-epic.json`                | `bd list --type epic --json`                                                      |
| `list-type-epic-status-open.json`    | `bd list --type epic --status open --json`                                        |
| `list-label-kind-phase.json`         | `bd list --label kind:phase --json`                                               |
| `list-label-kind-goal.json`          | `bd list --label kind:goal --json`                                                |
| `list-label-goal.json`               | `bd list --label goal-w7-retire-beads --json`                                     |
| `show-goal.json`                     | `bd show paperflow-7r9 --json`                                                    |
| `show-phase.json`                    | `bd show paperflow-xmb --json`                                                    |
| `show-work-task.json`                | `bd show paperflow-5wk --json`                                                    |
| `epic-close-eligible.json`           | `bd epic close-eligible --json`                                                   |
| `dep-add.txt`                        | regex: `bd dep add <child> <parent>` confirmation line                            |

Total: 13 JSON + 1 text fixture. Re-capture (after upstream `bd` upgrade):

```bash
cd ~/Documents/github/paperflow
FIX=<paperflow-pf>/test/fixtures/bd-shim
/opt/homebrew/bin/bd ready --json | jq -S . > $FIX/ready-all.json
# … (see test/bd-shim-fidelity.sh for the full set)
```
