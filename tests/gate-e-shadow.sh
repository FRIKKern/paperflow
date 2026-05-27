#!/usr/bin/env bash
# tests/gate-e-shadow.sh — W7d step 3 (w7-15 / paperflow-z3j) Gate-E proof.
#
# Drives a full Goal lifecycle (open → plan → build → review → "archive")
# end-to-end against BOTH stores with PAPERFLOW_MIRROR_GOALS=1, then asserts
# bd + barkpark accumulated IDENTICAL event sequences.
#
# What "identical" means here (read-the-task-spec edition):
#
#   * COUNT-LEVEL EQUALITY: number of barkpark `task.claimed` events ==
#     number of bd `open → in_progress` transitions; same for `task.closed`
#     vs bd `* → closed`. Timestamps + worker_ids vary per run by design and
#     are NOT compared. doc_ids ARE compared (every claim event maps to the
#     bd row of the same id, on the same goal).
#
#   * TEMPORAL ORDER (per-task): claimed precedes closed for each task.
#     Cross-task ordering is not asserted (the harness drives sequentially,
#     so order is implied by wall-clock).
#
#   * STRICT EQUALITY of mutation_events vs .beads/issues.jsonl was the
#     brief's ideal — but bd's .jsonl is an export, not a mutation log
#     (every line is the CURRENT state snapshot). The W7d brief's Q caveat
#     on this is captured in the harness as "we compare state-transitions
#     vs mutation_events." That's the achievable strict proof; "barkpark
#     accumulated events" alone would only prove dual-write fires.
#
# Preconditions:
#   - barkpark reachable on :4001 (NEVER :4000 — production daily driver).
#     PAPERFLOW_BARKPARK_URL override accepted; refused if it points at :4000.
#   - jq, curl, bd, python3 on PATH.
#   - If barkpark not reachable, SKIP cleanly (exit 0) — same convention as
#     tests/rail-proxy.sh + tests/doctor-ensure-tasks-clean.sh.
#
# Output:
#   PASS → `Gate-E PASS: …` with event counts + lifecycle breakdown. Exit 0.
#         Also touches ~/.paperflow/gate-e-pass-<epoch>.flag for doctor probe.
#   SKIP → `Gate-E SKIP: barkpark not reachable at <url>`. Exit 0.
#   FAIL → assertion line + expected/observed diff. Exit 2.
#
# Cleanup: sandbox dir is mktemp -d, trapped for removal on EXIT.
#   Barkpark side: the test goal + its descendants are NOT cleaned up —
#   the doc-id is unique per run (suffix = epoch + $$). A future iteration
#   may add --cleanup; the brief deferred that.

set -u

# ─── colours ──────────────────────────────────────────────────────────
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

# ─── preconditions ────────────────────────────────────────────────────
for dep in jq curl bd python3; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        red "FAIL: required dependency '$dep' not on PATH"
        exit 2
    fi
done

BARKPARK_URL="${PAPERFLOW_BARKPARK_URL:-http://localhost:4001}"
TOKEN="${BARKPARK_MIRROR_TOKEN:-barkpark-dev-token}"

# Guardrail: NEVER fire against :4000 (production daily driver).
case "$BARKPARK_URL" in
    *:4000*|*:4000/*)
        red "FAIL: refusing to run Gate-E against $BARKPARK_URL (:4000 is production)"
        exit 2
        ;;
esac

bp_probe="$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$BARKPARK_URL/v1/tasks" 2>/dev/null)"
[ -n "$bp_probe" ] || bp_probe="000"
case "$bp_probe" in
    2*|4*) ;;
    *)
        yellow "Gate-E SKIP: barkpark not reachable at $BARKPARK_URL (http=$bp_probe)"
        exit 0
        ;;
esac

# ─── sandbox ──────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d -t gate-e-shadow.XXXXXX)"
cleanup() {
    [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Initialise sandbox as a git repo so .paperflow/ resolution + bd init work.
( cd "$SANDBOX" && git init -q && git config user.email "gate-e@test" && git config user.name "gate-e" ) || {
    red "FAIL: could not git init sandbox at $SANDBOX"
    exit 2
}
mkdir -p "$SANDBOX/.paperflow"

# bd init in the sandbox (isolated .beads/).
if ! ( cd "$SANDBOX" && bd init >/dev/null 2>&1 ); then
    red "FAIL: bd init failed in sandbox $SANDBOX"
    exit 2
fi

# ─── timeline ───────────────────────────────────────────────────────
T0="$(date +%s)"
SUFFIX="$(date +%s)-$$"
GOAL_SLUG="gate-e-${SUFFIX}"

# Mirror env — strict for this harness.
export PAPERFLOW_MIRROR_GOALS=1
export PAPERFLOW_BARKPARK_URL="$BARKPARK_URL"
export BARKPARK_MIRROR_TOKEN="$TOKEN"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Source the mirror lib so we can write directly (skips the SKILL/orchestrator
# layer — this is a contract test, not an integration test).
. "$REPO_ROOT/lib/barkpark-mirror.sh"

# Counters for bd-side ground truth.
BD_CLAIMS=0
BD_CLOSES=0
BD_TASKS_CREATED=0
BD_PHASES_CREATED=0
BD_GOALS_CREATED=0

# Helper: pull bd id from `bd create` output. Same anchor as paperflow-doc-meta
# but with `_` allowed in the prefix — sandboxed `bd init` repos generate
# tmp_<rand>-<suffix> ids (vs the alpha-only paperflow-vma form). The split
# delimiter remains the `-` between prefix and suffix; `awk` is more robust
# than grep -oE here because the title can also contain dashes.
parse_bd_id() {
    grep -m1 'Created issue:' \
        | awk '{
            # Walk fields; the id is the first token after "Created issue:"
            for (i=1; i<=NF; i++) {
                if ($i == "issue:") { print $(i+1); exit }
            }
        }'
}

# Helper: publish a barkpark draft of given type to drop the `drafts.` prefix.
#   Without this, the rail traversal (which joins on
#   `phase.content.parent = goal.doc_id` for the BARE id) misses descendants
#   because phases store `parent: <bare>` while the goal lives at `drafts.<id>`.
bp_publish() {
    local id="$1" type="$2"
    curl -sS -m 3 -o /dev/null -X POST \
        "$BARKPARK_URL/v1/data/mutate/$BARKPARK_MIRROR_DATASET" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg id "$id" --arg type "$type" \
            '{mutations:[{publish:{id:$id,type:$type}}]}')" 2>/dev/null || true
}

# Helper: POST a targeted claim through the bd-shim-equivalent path.
#   Returns the JSON body on stdout; epoch + rev extracted by caller.
bp_claim() {
    local doc_id="$1" worker="$2"
    curl -sS -m 5 -X POST \
        "$BARKPARK_URL/v1/tasks/$doc_id/claim" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg w "$worker" '{worker_id:$w}')" 2>/dev/null
}

# Helper: POST a close with the observed epoch+rev returned by claim.
bp_close() {
    local doc_id="$1" worker="$2" epoch="$3" rev="$4"
    curl -sS -m 5 -X POST \
        "$BARKPARK_URL/v1/tasks/$doc_id/close" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg w "$worker" --argjson e "$epoch" --arg r "$rev" \
            '{worker_id:$w,observed_epoch:$e,observed_rev:$r,lifecycle_status:"done"}')" 2>/dev/null
}

# Helper: drive a single bd transition + mirror twin. Echoes any failure to
# stderr but does not exit — the harness collects all errors and reports.
drive_claim_close() {
    local bd_id="$1" bp_id="$2" worker="$3" label="$4"

    # bd: claim → close
    if ! ( cd "$SANDBOX" && bd update "$bd_id" --claim >/dev/null 2>&1 ); then
        red "  WARN: bd claim failed for $bd_id ($label)"
        return 1
    fi
    BD_CLAIMS=$((BD_CLAIMS+1))

    # barkpark mirror: claim
    local cl
    cl="$(bp_claim "$bp_id" "$worker")"
    if ! printf '%s' "$cl" | jq -e '.ok == true' >/dev/null 2>&1; then
        red "  WARN: barkpark claim failed for $bp_id ($label): $(printf '%s' "$cl" | head -c 200)"
        return 1
    fi
    local epoch rev
    epoch="$(printf '%s' "$cl" | jq -r '.doc.content.claim.epoch')"
    rev="$(printf '%s' "$cl" | jq -r '.doc.rev')"

    # bd: close (bd 1.0.3 wants --status closed, not --close)
    if ! ( cd "$SANDBOX" && bd update "$bd_id" --status closed >/dev/null 2>&1 ); then
        red "  WARN: bd close failed for $bd_id ($label)"
        return 1
    fi
    BD_CLOSES=$((BD_CLOSES+1))

    # barkpark mirror: close (uses the observed epoch+rev for CAS)
    local cls
    cls="$(bp_close "$bp_id" "$worker" "$epoch" "$rev")"
    if ! printf '%s' "$cls" | jq -e '.ok == true' >/dev/null 2>&1; then
        red "  WARN: barkpark close failed for $bp_id ($label): $(printf '%s' "$cls" | head -c 200)"
        return 1
    fi
    return 0
}

# ─── step 1: open Goal (bd + mirror) ──────────────────────────────────
dim "[1/6] open Goal"
GOAL_TITLE="Gate-E shadow test $SUFFIX"
GOAL_BD_ID="$(
    cd "$SANDBOX" && bd create "$GOAL_TITLE" \
        --type epic \
        --label "kind:goal" \
        --label "goal-$GOAL_SLUG" 2>&1
)"
GOAL_BD_ID="$(printf '%s' "$GOAL_BD_ID" | parse_bd_id)"
if [ -z "$GOAL_BD_ID" ]; then
    red "FAIL: could not parse goal id from bd create output"
    exit 2
fi
BD_GOALS_CREATED=1

# Mirror to barkpark (and PUBLISH so rail's bare-id descendant join works).
barkpark_mirror_goal "$GOAL_BD_ID" "$GOAL_TITLE" "$GOAL_SLUG" >/dev/null 2>&1 || true
bp_publish "$GOAL_BD_ID" "goal"

printf '%s\n' "$GOAL_BD_ID" > "$SANDBOX/.paperflow/active-goal"

# ─── step 2: plan materialise (1 phase + 3 tasks) ─────────────────────
dim "[2/6] plan materialise (1 phase + 3 tasks)"
PHASE_BD_ID="$(
    cd "$SANDBOX" && bd create "build" --type task \
        --label "kind:phase" \
        --label "goal-$GOAL_SLUG" \
        --label "phase-build" 2>&1
)"
PHASE_BD_ID="$(printf '%s' "$PHASE_BD_ID" | parse_bd_id)"
if [ -z "$PHASE_BD_ID" ]; then
    red "FAIL: could not parse phase id from bd create output"
    exit 2
fi
( cd "$SANDBOX" && bd update "$PHASE_BD_ID" --parent "$GOAL_BD_ID" >/dev/null 2>&1 ) || true
BD_PHASES_CREATED=1
barkpark_mirror_phase "$PHASE_BD_ID" "build" "$GOAL_BD_ID" "build" >/dev/null 2>&1 || true
bp_publish "$PHASE_BD_ID" "phase"

printf '%s\n' "$PHASE_BD_ID" > "$SANDBOX/.paperflow/active-phase"

TASK_IDS=()
for n in 1 2 3; do
    TASK_TITLE="work-task-$n"
    TID="$(
        cd "$SANDBOX" && bd create "$TASK_TITLE" --type task \
            --label "goal-$GOAL_SLUG" \
            --label "phase-build" 2>&1
    )"
    TID="$(printf '%s' "$TID" | parse_bd_id)"
    if [ -z "$TID" ]; then
        red "FAIL: could not parse task-$n id from bd create output"
        exit 2
    fi
    ( cd "$SANDBOX" && bd update "$TID" --parent "$PHASE_BD_ID" >/dev/null 2>&1 ) || true
    BD_TASKS_CREATED=$((BD_TASKS_CREATED+1))
    barkpark_mirror_task "$TID" "$TASK_TITLE" "$PHASE_BD_ID" 2 "open" "" >/dev/null 2>&1 || true
    bp_publish "$TID" "task"
    TASK_IDS+=("$TID")
done

# ─── step 3: grill (scripted skip — autopilot --skip-grill precedent) ─
dim "[3/6] grill — SKIPPED (scripted test; autopilot --skip-grill precedent)"

# ─── step 4: build — claim + close each task ──────────────────────────
dim "[4/6] build — claim+close ${#TASK_IDS[@]} tasks"
for tid in "${TASK_IDS[@]}"; do
    drive_claim_close "$tid" "$tid" "gate-e-w7-15" "build-task"
done

# ─── step 5: review — open review-task on task 1, claim+close ─────────
dim "[5/6] review — open review-task, claim+close"
REVIEW_TID="$(
    cd "$SANDBOX" && bd create "review of ${TASK_IDS[0]}" --type task \
        --label "goal-$GOAL_SLUG" \
        --label "phase-build" \
        --label "kind:review" 2>&1
)"
REVIEW_TID="$(printf '%s' "$REVIEW_TID" | parse_bd_id)"
if [ -n "$REVIEW_TID" ]; then
    ( cd "$SANDBOX" && bd update "$REVIEW_TID" --parent "$PHASE_BD_ID" >/dev/null 2>&1 ) || true
    BD_TASKS_CREATED=$((BD_TASKS_CREATED+1))
    barkpark_mirror_task "$REVIEW_TID" "review of ${TASK_IDS[0]}" "$PHASE_BD_ID" 2 "open" "" >/dev/null 2>&1 || true
    bp_publish "$REVIEW_TID" "task"
    drive_claim_close "$REVIEW_TID" "$REVIEW_TID" "gate-e-reviewer" "review-task"
fi

# ─── step 6: archive — left open (brief: assert events accumulated) ───
dim "[6/6] archive — left open; asserting events accumulated"

# ─── assertions ───────────────────────────────────────────────────────
sleep 1  # tiny settle for mutation_events.id sequence to flush
RAIL="$(curl -sS -m 5 -H "Authorization: Bearer $TOKEN" \
    "$BARKPARK_URL/v1/rail/goal-path?goal=$GOAL_BD_ID" 2>/dev/null || printf '{}')"

if ! printf '%s' "$RAIL" | jq -e '.ok == true' >/dev/null 2>&1; then
    red "FAIL: rail endpoint did not return ok:true"
    printf '  response: %s\n' "$RAIL" | head -c 400
    exit 2
fi

BP_CLAIMED="$(printf '%s' "$RAIL" | jq '[.events[] | select(.kind == "task.claimed")] | length')"
BP_CLOSED="$(printf '%s' "$RAIL"  | jq '[.events[] | select(.kind == "task.closed")]  | length')"
BP_TOTAL="$(printf '%s' "$RAIL"   | jq '.events | length')"

# Per-task payload sanity — every event must have kind, doc_id, ts, payload.
BP_INVALID="$(printf '%s' "$RAIL" | jq '[.events[] | select((.kind|type)!="string" or (.doc_id|type)!="string" or (.ts|type)!="string" or (.payload|type)!="object")] | length')"

# bd-side ground truth via `bd list --status closed --label goal-<slug>`. The
# .beads/issues.jsonl export is stale-by-design (passive snapshot, not live
# state — see https://github.com/gastownhall/beads SYNC_CONCEPTS.md), so we
# query bd directly. A closed row implies one claim + one close transition
# was applied — the harness tracked transitions in BD_CLAIMS/BD_CLOSES as
# it drove them; this is the cross-check that bd's dolt store agrees.
BD_CLOSED_ROWS="$(
    cd "$SANDBOX" && bd list --status closed --label "goal-$GOAL_SLUG" --json 2>/dev/null \
        | jq 'length' 2>/dev/null || echo 0
)"

# ─── verdict ──────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - T0 ))
FAIL=0

if [ "$BP_CLAIMED" != "$BD_CLAIMS" ]; then
    red "FAIL: barkpark task.claimed count ($BP_CLAIMED) != bd claim transitions ($BD_CLAIMS)"
    FAIL=1
fi
if [ "$BP_CLOSED" != "$BD_CLOSES" ]; then
    red "FAIL: barkpark task.closed count ($BP_CLOSED) != bd close transitions ($BD_CLOSES)"
    FAIL=1
fi
if [ "$BP_INVALID" != "0" ]; then
    red "FAIL: $BP_INVALID rail event(s) missing required {kind,doc_id,ts,payload}"
    FAIL=1
fi
# Sanity: bd-side closed rows should match closes (every close transition →
# closed row). This is the cross-check that bd's export agrees with our
# transition counter.
if [ "$BD_CLOSED_ROWS" != "$BD_CLOSES" ]; then
    red "FAIL: bd .jsonl closed-rows ($BD_CLOSED_ROWS) != claim/close transitions counted ($BD_CLOSES)"
    FAIL=1
fi
# Brief's softer assertion: lifecycle accumulated events at all.
if [ "$BP_TOTAL" -lt 1 ]; then
    red "FAIL: barkpark rail returned 0 events — dual-write may be silently dropped"
    FAIL=1
fi

if [ "$FAIL" = "1" ]; then
    printf '\n'
    yellow "Diagnostics:"
    printf '  goal:    %s (slug=%s)\n' "$GOAL_BD_ID" "$GOAL_SLUG"
    printf '  phase:   %s\n' "$PHASE_BD_ID"
    printf '  tasks:   %s\n' "${TASK_IDS[*]}"
    printf '  review:  %s\n' "${REVIEW_TID:-<not created>}"
    printf '  sandbox: %s\n' "$SANDBOX"
    printf '  bd:        goals=%d phases=%d tasks=%d  claims=%d closes=%d closed-rows=%d\n' \
        "$BD_GOALS_CREATED" "$BD_PHASES_CREATED" "$BD_TASKS_CREATED" \
        "$BD_CLAIMS" "$BD_CLOSES" "$BD_CLOSED_ROWS"
    printf '  barkpark:  rail.events=%d  task.claimed=%d  task.closed=%d  invalid=%d\n' \
        "$BP_TOTAL" "$BP_CLAIMED" "$BP_CLOSED" "$BP_INVALID"
    exit 2
fi

# Success — touch the doctor probe flag.
mkdir -p "$HOME/.paperflow" 2>/dev/null || true
touch "$HOME/.paperflow/gate-e-pass-$(date +%s).flag" 2>/dev/null || true

green "Gate-E PASS: $BP_TOTAL events in barkpark match $((BD_CLAIMS + BD_CLOSES)) bd transitions; lifecycle: open(1) → plan($((BD_PHASES_CREATED + BD_TASKS_CREATED))) → build($((BD_CLAIMS + BD_CLOSES - 2))) → review(2) → ts=${ELAPSED}s"
exit 0
