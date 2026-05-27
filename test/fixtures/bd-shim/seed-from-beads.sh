#!/usr/bin/env bash
# w7-08 — seed the configured Barkpark with the minimum task/goal/phase
# rows the fidelity fixtures reference. Uses the existing legacy
# /api/documents/:type POST endpoint (BarkparkWeb.LegacyController.create
# → Content.upsert_document) so the Tasks validators run as-real-life.
#
# Usage:
#   BARKPARK_URL=http://localhost:4001 ./test/fixtures/bd-shim/seed-from-beads.sh
#
# Idempotent — re-runs upsert by doc_id.

set -euo pipefail

: "${BARKPARK_URL:=http://localhost:4001}"
: "${BARKPARK_TOKEN:=barkpark-dev-token}"

post() {
  local path="$1"
  local body="$2"
  curl -s -X POST "$BARKPARK_URL$path" \
    -H "Authorization: Bearer $BARKPARK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body" \
    -o /dev/null -w "%{http_code}\n"
}

# Goal (paperflow-7r9)
post /api/documents/goal '{
  "id":"paperflow-7r9",
  "title":"Wave 7 — retire Beads onto Postgres document substrate",
  "kind":"goal",
  "goal_slug":"w7-retire-beads"
}'

# Phase (paperflow-xmb) — child of the goal
post /api/documents/phase '{
  "id":"paperflow-xmb",
  "title":"Wave 7 build phase",
  "kind":"phase",
  "phase_name":"build",
  "parent":"drafts.paperflow-7r9",
  "lifecycle_status":"open"
}'

# Work-task (paperflow-5wk) — w7-08c: include description so the rendered
# shape carries it (matches the captured list-all + show-work-task shapes
# whose first element has a non-null description string).
post /api/documents/task '{
  "id":"paperflow-5wk",
  "title":"w7-08 fidelity snapshot",
  "kind":"task",
  "lifecycle_status":"open",
  "parent_id":"drafts.paperflow-xmb",
  "assignee":"Frikkern",
  "priority":2,
  "description":"w7-08 JSON-shape snapshot tests + dock health probe — all reader calls round-trip byte-shape-equal"
}'

# w7-08c: flip the task to in_progress via the tasks claim endpoint so it
# carries `content.claim.ts_iso` (rendered as `started_at` per
# renderShowShape / renderListShape's startedAtFor/1). Element[0] of the
# list/show shapes assumes a started, in-progress task. Idempotent enough —
# a second claim returns 409 not_ready which is fine (the row stays
# in_progress from the first run).
post /v1/tasks/drafts.paperflow-5wk/claim '{"worker_id":"bd-shim-seed"}' || true

echo "seed done"
