## Step 0.5 — Doc metadata (mandatory)

Before writing any HTML doc, call:

    ~/.local/bin/paperflow-doc-meta

Parse the JSON. Embed `time_display`, `device`, and `cmux_workspace` (if non-null) into the doc's `<div class="byline">` as additional `<span>` elements alongside the existing date / topic / status spans. The byline should now read:

    <div class="byline">
      <span>2026-05-10 · 17:42 CEST</span>     <!-- date + time_display from helper -->
      <span>Topic / category</span>
      <span>One-phrase status or conclusion</span>
      <span>Mac · cmux-workspace-3</span>      <!-- device · cmux_workspace from helper -->
    </div>

Embed `active_goal_id` into the required script tail:

    <script>
      window.CLAUDE_TARGET = { ... };
      window.DOC_PATH = "<this-filename>.html";
      window.PAPERFLOW_GOAL_ID = "<active_goal_id from helper>";
    </script>

If the helper auto-created a session Goal (`auto_created: true` in the JSON), surface that to the user in the chat reply: "Auto-created session Goal `<title>` for this doc — rename it whenever via `bd update <id> --title …`."

Never invent or guess these values — always shell out to the helper.
