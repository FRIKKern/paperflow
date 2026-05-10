## Step 0 — Runtime preflight + doctor

Before doing anything else, validate that the message-carrying runtime is up and the install is healthy.

**1. Runtime probe.**

    ~/.local/bin/paperflow-preflight

Non-zero → abort the skill and paste the JSON from stdout to the user verbatim. The JSON carries `service`, `mode` (`cmux` or `launchagent`), `repair_command`, and `log_tail` — the user runs the repair, then re-invokes the skill.

**2. Doctor (deps + version + integrity).**

    ~/.local/bin/paperflow-doctor --fast

Read the JSON from stdout and react by exit code:

| Exit | Meaning | Action |
|---|---|---|
| 0 | Clean | Continue silent. |
| 1 | Warnings (outdated, optional dep missing, drift already auto-fixed) | Continue. Print a one-line summary at the start of the skill's main work: `Doctor: N warning(s) — run paperflow-doctor --full to inspect.` |
| 2 | Critical (bd/node missing, settings.json corrupted) | Abort. For each issue with `auto_fix_safe:false`, surface the `repair_command` and ask the user with `AskUserQuestion` whether to run it. |
