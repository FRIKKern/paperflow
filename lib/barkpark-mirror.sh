# lib/barkpark-mirror.sh — W7c step 1 (paperflow-4rk) goal/phase dual-write
# helper. Sourced by `bin/paperflow-doc-meta` (goal mirror) and
# `bin/paperflow-mirror-phase` (phase mirror). NEVER blocks the caller —
# every write is fire-and-forget on the barkpark side with a 3 s curl
# timeout, and failures are logged to ~/.paperflow/doc-meta-mirror.log
# rather than surfaced as exit-code noise.
#
# CONTRACT — the W7c-is-reversible guarantee:
#   * No-op when PAPERFLOW_MIRROR_GOALS is unset / not "1".
#   * No-op when PAPERFLOW_BARKPARK_URL is empty.
#   * curl --max-time 3, errors swallowed → bd create stays authoritative.
#   * Daily-driver behaviour is byte-identical to today when neither env
#     var is set.
#
# The barkpark write-shape matches W7-01's task substrate:
#   * type='goal' with content.kind='goal' + content.goal_slug
#   * type='phase' with content.kind='phase' + content.phase_name +
#     content.parent (= parent goal doc_id)
#   The brief's "type='task' + content.kind='goal'" was the older W7-01
#   draft shape; the substrate that actually landed splits the types
#   (see Barkpark.Tasks.validate_kind_content/2 + the GET /v1/tasks
#   `where: d.type in ["task","goal","phase","event"]` filter).
#
# Tenancy: posts hit /v1/data/mutate/production. The :api pipeline's
# AssignDefaultScope plug stamps Default Workspace + Default Project +
# resolves dataset_id from the "production" string, so the write lands
# fully tenancy-stamped without the helper needing to know any UUIDs.
# This is the same path the legacy mutate API has used for two years —
# it threads through Content.create_document/4 → put_scope_attrs/2 →
# resolve_dataset_id_for_write/2, which avoids the get_document
# coalescence bug the bd-shim work routed around (that bug is on the
# READ path, not writes).

# Public:
#   barkpark_mirror_goal  <goal_id> <title> [<slug>]
#   barkpark_mirror_phase <phase_id> <phase_name> <parent_goal_id> [<title>]
# Both return 0 always — caller must not branch on exit code.

BARKPARK_MIRROR_LOG="${BARKPARK_MIRROR_LOG:-$HOME/.paperflow/doc-meta-mirror.log}"
BARKPARK_MIRROR_TOKEN="${BARKPARK_MIRROR_TOKEN:-barkpark-dev-token}"
BARKPARK_MIRROR_DATASET="${BARKPARK_MIRROR_DATASET:-production}"

# Internal: write a one-line log entry. Never fails the caller.
_barkpark_mirror_log() {
    local msg="$1"
    mkdir -p "$(dirname "$BARKPARK_MIRROR_LOG")" 2>/dev/null || true
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)" "$msg" \
        >> "$BARKPARK_MIRROR_LOG" 2>/dev/null || true
}

# Internal: returns 0 if the helper should attempt a mirror, 1 otherwise.
_barkpark_mirror_enabled() {
    [ "${PAPERFLOW_MIRROR_GOALS:-0}" = "1" ] || return 1
    [ -n "${PAPERFLOW_BARKPARK_URL:-}" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    return 0
}

# Internal: derive a slug from the goal id when caller didn't supply one.
# "paperflow-vma" → "vma" (just the suffix; matches paperflow's existing
# goal-<slug> label convention used in the goal SKILL).
_barkpark_mirror_default_slug() {
    local id="$1"
    case "$id" in
        *-*) printf '%s' "${id##*-}" ;;
        *)   printf '%s' "$id" ;;
    esac
}

# barkpark_mirror_goal <goal_id> <title> [<slug>]
barkpark_mirror_goal() {
    local goal_id="$1" title="$2" slug="${3:-}"
    [ -n "$goal_id" ] || { _barkpark_mirror_log "skip: missing goal_id"; return 0; }
    _barkpark_mirror_enabled || return 0

    [ -n "$slug" ] || slug="$(_barkpark_mirror_default_slug "$goal_id")"

    # createIfNotExists matches the safe-dual-write contract — second call
    # for the same goal_id is a no-op rather than an overwrite. The W7-01
    # validator rejects content.lifecycle_status on goals (not in its
    # optional list), so it's omitted from the write shape and inferred as
    # "open" on read via the controller's COALESCE default.
    local payload
    payload="$(jq -nc \
        --arg id   "$goal_id" \
        --arg title "$title" \
        --arg slug "$slug" \
        --arg label_kind "kind:goal" \
        --arg label_goal "goal-$slug" \
        '{
           mutations: [
             { createIfNotExists: {
                 _type: "goal",
                 _id: $id,
                 doc_id: $id,
                 title: $title,
                 content: {
                   kind: "goal",
                   goal_slug: $slug,
                   papers: [],
                   labels: [$label_kind, $label_goal]
                 }
             }}
           ]
         }')" || { _barkpark_mirror_log "skip: jq failed for goal $goal_id"; return 0; }

    local out rc
    out="$(curl -sS --max-time 3 \
        -X POST "$PAPERFLOW_BARKPARK_URL/v1/data/mutate/$BARKPARK_MIRROR_DATASET" \
        -H "Authorization: Bearer $BARKPARK_MIRROR_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        _barkpark_mirror_log "warn: goal mirror curl failed rc=$rc id=$goal_id err=$out"
        return 0
    fi
    # Detect mutation-level error (HTTP 200 but error envelope).
    case "$out" in
        *'"transactionId"'*) _barkpark_mirror_log "ok: goal $goal_id mirrored ($slug)" ;;
        *)                   _barkpark_mirror_log "warn: goal mirror returned err id=$goal_id resp=$out" ;;
    esac
    return 0
}

# barkpark_mirror_phase <phase_id> <phase_name> <parent_goal_id> [<title>]
barkpark_mirror_phase() {
    local phase_id="$1" phase_name="$2" parent_id="$3" title="${4:-$phase_name}"
    [ -n "$phase_id" ] || { _barkpark_mirror_log "skip: missing phase_id"; return 0; }
    [ -n "$phase_name" ] || { _barkpark_mirror_log "skip: missing phase_name for $phase_id"; return 0; }
    _barkpark_mirror_enabled || return 0

    local payload
    payload="$(jq -nc \
        --arg id     "$phase_id" \
        --arg title  "$title" \
        --arg pname  "$phase_name" \
        --arg parent "$parent_id" \
        --arg label_kind  "kind:phase" \
        --arg label_phase "phase-$phase_name" \
        '{
           mutations: [
             { createIfNotExists: {
                 _type: "phase",
                 _id: $id,
                 doc_id: $id,
                 title: $title,
                 content: {
                   kind: "phase",
                   phase_name: $pname,
                   parent: $parent,
                   labels: [$label_kind, $label_phase]
                 }
             }}
           ]
         }')" || { _barkpark_mirror_log "skip: jq failed for phase $phase_id"; return 0; }

    local out rc
    out="$(curl -sS --max-time 3 \
        -X POST "$PAPERFLOW_BARKPARK_URL/v1/data/mutate/$BARKPARK_MIRROR_DATASET" \
        -H "Authorization: Bearer $BARKPARK_MIRROR_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        _barkpark_mirror_log "warn: phase mirror curl failed rc=$rc id=$phase_id err=$out"
        return 0
    fi
    case "$out" in
        *'"transactionId"'*) _barkpark_mirror_log "ok: phase $phase_id mirrored ($phase_name → $parent_id)" ;;
        *)                   _barkpark_mirror_log "warn: phase mirror returned err id=$phase_id resp=$out" ;;
    esac
    return 0
}
