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
  local type="$1"
  local body="$2"
  curl -s -X POST "$BARKPARK_URL/api/documents/$type" \
    -H "Authorization: Bearer $BARKPARK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body" \
    -o /dev/null -w "%{http_code}\n"
}

# Goal (paperflow-7r9)
post goal '{
  "id":"paperflow-7r9",
  "title":"Wave 7 — retire Beads onto Postgres document substrate",
  "kind":"goal",
  "goal_slug":"w7-retire-beads"
}'

# Phase (paperflow-xmb) — child of the goal
post phase '{
  "id":"paperflow-xmb",
  "title":"Wave 7 build phase",
  "kind":"phase",
  "phase_name":"build",
  "parent":"drafts.paperflow-7r9",
  "lifecycle_status":"open"
}'

# Work-task (paperflow-5wk)
post task '{
  "id":"paperflow-5wk",
  "title":"w7-08 fidelity snapshot",
  "kind":"task",
  "lifecycle_status":"open",
  "parent_id":"drafts.paperflow-xmb",
  "assignee":"Frikkern",
  "priority":2
}'

echo "seed done"
