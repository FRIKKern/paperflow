#!/usr/bin/env bash
# paperflow statusline — one-line bottom-bar renderer for Claude Code.
#
# Reads the JSON Claude Code pipes to stdin, renders a single line:
#   137,420 / 1M · 1209d022 · paperflow · main
#
# Hot path target: < 10 ms when the transcript cache is fresh.
# Cold path: 50–200 ms one-off when the cache is stale.
#
# Per-tool degradation:
#   jq missing      → silent-fallback, empty stdout, exit 0
#   git missing     → drop branch
#   shasum missing  → run uncached (CACHE="")
#
# Debug log opt-in:
#   STATUSLINE_DEBUG=1 → ~/.paperflow/statusline-debug.log

set -eu

# ─── Globals ─────────────────────────────────────────────────────────
SESSION_ID=""
TRANSCRIPT_PATH=""
CWD=""
MODEL_ID=""
PROJECT_DIR=""
MODEL_DISPLAY=""

TOKENS=""
LIMIT=""
SID_SHORT=""
PROJECT=""
BRANCH=""

# Goal / phase / task segments — populated by resolve_goal_phase_task() when a
# repo has .paperflow/active-goal + .paperflow/active-phase pointers and bd is
# on PATH. Empty otherwise; truncate_to_width() drops them silently.
GOAL_SLUG=""        # e.g. "onboarding-revamp"
PHASE_NAME=""       # e.g. "build"
PHASE_INDEX=""      # e.g. "2"  (1-based position among the goal's phase-tasks)
PHASE_TOTAL=""      # e.g. "3"  (total phase-tasks under the goal)
TASK_ID=""          # e.g. "bd-a1b2.2.3"
TASK_TITLE=""       # e.g. "wire-bridge" (truncated to ~24 chars)
TASKS_DONE=""       # closed work-tasks under the active phase
TASKS_TOTAL=""      # total work-tasks under the active phase

CACHE=""
LIMITS_TSV=""
LIMITS_DEFAULT=""

SOURCE="unset"
FALLBACK_REASON=""

PAPERFLOW_DIR="$HOME/.paperflow"
CACHE_DIR="$PAPERFLOW_DIR/statusline-cache"
LIMITS_FILE="$PAPERFLOW_DIR/statusline-limits.json"
LIMITS_CACHE="$CACHE_DIR/.limits-cache.txt"
CLEANUP_STAMP="$CACHE_DIR/.last-cleanup"
DEBUG_LOG="$PAPERFLOW_DIR/statusline-debug.log"

# Pre-rendered cache: written by Beads-mutating skills, read here on the hot
# path. If present and fresh (< 30 s since mtime), the renderer skips live
# composition entirely and just cats the file.
PRERENDER_CACHE="$PAPERFLOW_DIR/statusline.txt"
PRERENDER_MAX_AGE=30

# ─── Helpers ─────────────────────────────────────────────────────────

# Append a single tab-separated line to the debug log when STATUSLINE_DEBUG=1.
debug_log() {
    [ "${STATUSLINE_DEBUG:-0}" = "1" ] || return 0
    local rendered="${1:-}"
    mkdir -p "$PAPERFLOW_DIR" 2>/dev/null || return 0
    local ts
    ts=$(date +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || echo "")
    local sid_for_log="${SID_SHORT:-unknown}"
    printf '%s\tsid=%s\ttranscript=%s\tsource=%s\tstdout=%s\n' \
        "$ts" "$sid_for_log" "$TRANSCRIPT_PATH" "$SOURCE" "$rendered" \
        >> "$DEBUG_LOG" 2>/dev/null || true
}

# Strip control bytes, keep printable ASCII, take first line. Stdin → stdout.
sanitise() {
    tr -d '\000-\037\177' 2>/dev/null | sed 's/[^[:print:]]//g' 2>/dev/null | head -n 1 2>/dev/null
}

# Read all of stdin and parse session_id, transcript_path, cwd, model id,
# workspace.project_dir, model.display_name. Hard fails iff jq is missing.
read_stdin_json() {
    if ! command -v jq >/dev/null 2>&1; then
        SOURCE="silent-fallback:jq-missing"
        FALLBACK_REASON="jq-missing"
        return 1
    fi

    local payload
    payload=$(cat 2>/dev/null || true)
    if [ -z "$payload" ]; then
        SOURCE="silent-fallback:stdin-malformed"
        FALLBACK_REASON="stdin-empty"
        return 1
    fi

    local parsed
    parsed=$(printf '%s' "$payload" | jq -r '
        [
            (.session_id // ""),
            (.transcript_path // ""),
            (.cwd // .workspace.current_dir // ""),
            (.model.id // .model // ""),
            (.workspace.project_dir // ""),
            (.model.display_name // "")
        ] | @tsv
    ' 2>/dev/null) || {
        SOURCE="silent-fallback:stdin-malformed"
        FALLBACK_REASON="jq-stdin-error"
        return 1
    }

    if [ -z "$parsed" ]; then
        SOURCE="silent-fallback:stdin-malformed"
        FALLBACK_REASON="empty-parse"
        return 1
    fi

    # Decompose tsv (six fields). IFS-tab read.
    local f1 f2 f3 f4 f5 f6
    IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 <<EOF
$parsed
EOF
    SESSION_ID="${f1:-}"
    TRANSCRIPT_PATH="${f2:-}"
    CWD="${f3:-}"
    MODEL_ID="${f4:-}"
    PROJECT_DIR="${f5:-}"
    MODEL_DISPLAY="${f6:-}"

    SID_SHORT=$(printf '%s' "$SESSION_ID" | tr -d '-' | cut -c1-8)
    return 0
}

# Compute cache file path (uncached if shasum missing).
cache_path() {
    if ! command -v shasum >/dev/null 2>&1; then
        CACHE=""
        return 0
    fi
    if [ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT_PATH" ]; then
        CACHE=""
        return 0
    fi
    local hash
    hash=$(printf '%s:%s' "$SESSION_ID" "$TRANSCRIPT_PATH" \
        | shasum 2>/dev/null | cut -c1-40) || hash=""
    if [ -z "$hash" ]; then
        CACHE=""
        return 0
    fi
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
    CACHE="$CACHE_DIR/$hash.txt"
}

# Read limits.json with mtime-keyed cache. Populates LIMITS_TSV and LIMITS_DEFAULT.
parse_limits_cached() {
    LIMITS_TSV=""
    LIMITS_DEFAULT=""

    if [ ! -r "$LIMITS_FILE" ]; then
        return 0
    fi

    local mtime
    mtime=$(stat -f %m "$LIMITS_FILE" 2>/dev/null || stat -c %Y "$LIMITS_FILE" 2>/dev/null || echo "")
    [ -z "$mtime" ] && return 0

    if [ -r "$LIMITS_CACHE" ]; then
        local cached_mtime
        cached_mtime=$(head -n 1 "$LIMITS_CACHE" 2>/dev/null || echo "")
        if [ "$cached_mtime" = "$mtime" ]; then
            # Body lines are model_id\tlimit, plus a __default__ row.
            LIMITS_TSV=$(tail -n +2 "$LIMITS_CACHE" 2>/dev/null || echo "")
            local def
            def=$(printf '%s\n' "$LIMITS_TSV" | awk -F'\t' '$1=="__default__" {print $2; exit}')
            LIMITS_DEFAULT="${def:-}"
            return 0
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi

    local limits_body default_val
    limits_body=$(jq -r '.limits | to_entries[] | "\(.key)\t\(.value)"' "$LIMITS_FILE" 2>/dev/null || echo "")
    default_val=$(jq -r '.default // 1000000' "$LIMITS_FILE" 2>/dev/null || echo "1000000")
    LIMITS_DEFAULT="$default_val"

    LIMITS_TSV="$limits_body"
    if [ -n "$default_val" ]; then
        LIMITS_TSV="$LIMITS_TSV
__default__	$default_val"
    fi

    mkdir -p "$CACHE_DIR" 2>/dev/null || true
    local tmp
    tmp=$(mktemp 2>/dev/null) || return 0
    trap 'rm -f "$tmp"' EXIT
    {
        printf '%s\n' "$mtime"
        printf '%s\n' "$LIMITS_TSV"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; trap - EXIT; return 0; }
    mv "$tmp" "$LIMITS_CACHE" 2>/dev/null || rm -f "$tmp"
    trap - EXIT
}

# Look up limit for MODEL_ID in LIMITS_TSV; fall back to LIMITS_DEFAULT, then 1000000.
get_limit() {
    LIMIT="1000000"
    if [ -n "$LIMITS_DEFAULT" ]; then
        LIMIT="$LIMITS_DEFAULT"
    fi
    if [ -n "$MODEL_ID" ] && [ -n "$LIMITS_TSV" ]; then
        local hit
        hit=$(printf '%s\n' "$LIMITS_TSV" | awk -F'\t' -v m="$MODEL_ID" '$1==m {print $2; exit}')
        if [ -n "$hit" ]; then
            LIMIT="$hit"
            return 0
        fi
        # Unknown model — log a breadcrumb.
        if [ "${STATUSLINE_DEBUG:-0}" = "1" ]; then
            local prev_source="$SOURCE"
            SOURCE="info:model-unknown:$MODEL_ID"
            debug_log ""
            SOURCE="$prev_source"
        fi
    fi
}

# Tail two transcript lines, sum the latest assistant turn's input + cache_*.
parse_token_count() {
    TOKENS=""

    if [ -z "$TRANSCRIPT_PATH" ]; then
        SOURCE="fresh-session"
        TOKENS="0"
        return 0
    fi

    if [ ! -e "$TRANSCRIPT_PATH" ]; then
        SOURCE="fresh-session"
        TOKENS="0"
        return 0
    fi

    if [ ! -r "$TRANSCRIPT_PATH" ]; then
        SOURCE="silent-fallback:transcript-unreadable"
        TOKENS=""
        return 0
    fi

    local mtime
    mtime=$(stat -f %m "$TRANSCRIPT_PATH" 2>/dev/null || stat -c %Y "$TRANSCRIPT_PATH" 2>/dev/null || echo "")

    # Cache hit?
    if [ -n "$CACHE" ] && [ -r "$CACHE" ] && [ -n "$mtime" ]; then
        local cached_tokens cached_mtime
        cached_tokens=$(sed -n '1p' "$CACHE" 2>/dev/null || echo "")
        cached_mtime=$(sed -n '2p' "$CACHE" 2>/dev/null || echo "")
        if [ -n "$cached_tokens" ] && [ "$cached_mtime" = "$mtime" ]; then
            TOKENS="$cached_tokens"
            SOURCE="cache-hit"
            return 0
        fi
    fi

    # Cold path — recompute.
    local tail_out parse_out
    tail_out=$(tail -n 2 "$TRANSCRIPT_PATH" 2>/dev/null || echo "")
    if [ -z "$tail_out" ]; then
        SOURCE="fresh-session"
        TOKENS="0"
    else
        # Two-stage jq: round-trip per line, then pick latest assistant turn with usage.
        # Detect last vs penultimate by counting parsed objects.
        local parsed_count
        parsed_count=$(printf '%s\n' "$tail_out" | jq -R 'fromjson? // empty' 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
        parse_out=$(printf '%s\n' "$tail_out" \
            | jq -R 'fromjson? // empty' 2>/dev/null \
            | jq -s '
                [ .[]
                  | select(.type == "assistant")
                  | select(.message.usage)
                  | .message.usage
                ]
                | last
                | if . == null then 0
                  else
                    (.input_tokens // 0)
                    + (.cache_read_input_tokens // 0)
                    + (.cache_creation_input_tokens // 0)
                  end
            ' 2>/dev/null || echo "")
        if [ -n "$parse_out" ]; then
            TOKENS="$parse_out"
            # Lines fed in: $tail_out had at most 2 lines. If parsed_count < 2,
            # the last line failed parsing — penultimate-source.
            local total_lines
            total_lines=$(printf '%s' "$tail_out" | awk 'END{print NR}')
            if [ "${parsed_count:-0}" -lt "${total_lines:-0}" ]; then
                SOURCE="jq-penultimate"
            else
                SOURCE="jq-last-line"
            fi
        else
            SOURCE="silent-fallback:both-lines-failed"
            TOKENS=""
        fi
    fi

    # Atomic cache write.
    if [ -n "$CACHE" ] && [ -n "$TOKENS" ] && [ -n "$mtime" ]; then
        local tmp
        tmp=$(mktemp 2>/dev/null) || return 0
        trap 'rm -f "$tmp"' EXIT
        {
            printf '%s\n' "$TOKENS"
            printf '%s\n' "$mtime"
        } > "$tmp" 2>/dev/null || { rm -f "$tmp"; trap - EXIT; return 0; }
        mv "$tmp" "$CACHE" 2>/dev/null || rm -f "$tmp"
        trap - EXIT
    fi
}

# Resolve git branch from CWD; empty when git missing or not a repo.
get_branch() {
    BRANCH=""
    if ! command -v git >/dev/null 2>&1; then
        return 0
    fi
    [ -z "$CWD" ] && return 0
    [ -d "$CWD" ] || return 0
    local b
    b=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [ -z "$b" ] && return 0
    [ "$b" = "HEAD" ] && return 0
    BRANCH=$(printf '%s' "$b" | sanitise)
}

# Format integer with commas (POSIX-portable).
format_with_commas() {
    local n="${1:-0}"
    # Strip non-digits (the count must be an integer).
    n=$(printf '%s' "$n" | tr -cd '0-9')
    [ -z "$n" ] && n="0"
    # Use sed reverse trick.
    printf '%s' "$n" | awk '{
        s=$0
        out=""
        while (length(s) > 3) {
            out = "," substr(s, length(s)-2) out
            s = substr(s, 1, length(s)-3)
        }
        print s out
    }'
}

# ANSI color helpers — all honour the NO_COLOR env-var convention
# (https://no-color.org). When NO_COLOR is set and non-empty they emit
# the empty string, so output is byte-identical to the un-coloured form.

# Return the ANSI colour escape for a token count.
#   <50000          → green   (\033[32m)
#   50000–99999     → yellow  (\033[33m)
#   ≥100000         → red     (\033[31m)
# Empty $TOKENS or NO_COLOR set → empty string.
color_for_tokens() {
    [ -n "${NO_COLOR:-}" ] && { printf ''; return 0; }
    [ -z "${TOKENS:-}" ] && { printf ''; return 0; }
    awk -v t="$TOKENS" 'BEGIN {
        if (t+0 < 50000) printf "\033[32m"
        else if (t+0 < 100000) printf "\033[33m"
        else printf "\033[31m"
    }'
}

# Dim-on / reset escapes (also NO_COLOR-aware).
ansi_dim()   { [ -n "${NO_COLOR:-}" ] && printf '' || printf '\033[2m'; }
ansi_reset() { [ -n "${NO_COLOR:-}" ] && printf '' || printf '\033[0m'; }

# Compute tokens-as-percentage-of-limit, one-decimal.
# Empty/zero limit → "0.0". Stdin: none. Stdout: "13.7" etc.
compute_percentage() {
    awk -v t="${TOKENS:-0}" -v w="${LIMIT:-0}" 'BEGIN {
        if (w+0 == 0) print "0.0"
        else printf "%.1f", (t/w)*100
    }'
}

# Format a limit like 1000000 → "1M", 200000 → "200k".
format_limit() {
    local n="${1:-0}"
    n=$(printf '%s' "$n" | tr -cd '0-9')
    [ -z "$n" ] && { printf '0'; return; }
    if [ "$n" -ge 1000000 ] && [ $((n % 1000000)) -eq 0 ]; then
        printf '%dM' "$((n / 1000000))"
    elif [ "$n" -ge 1000 ] && [ $((n % 1000)) -eq 0 ]; then
        printf '%dk' "$((n / 1000))"
    else
        printf '%s' "$n"
    fi
}

# Walk up from CWD to nearest .paperflow/ directory; print its parent on stdout
# (the "repo root" for paperflow purposes), or empty if none found. POSIX-ish.
find_paperflow_repo_root() {
    local dir="${1:-$CWD}"
    [ -z "$dir" ] && return 0
    [ -d "$dir" ] || return 0
    while [ "$dir" != "/" ] && [ -n "$dir" ]; do
        if [ -d "$dir/.paperflow" ]; then
            printf '%s' "$dir"
            return 0
        fi
        dir=$(dirname "$dir" 2>/dev/null || echo "/")
    done
    return 0
}

# Resolve goal-task slug + phase-task name + phase index/total + claimed task
# + task counts via `bd show` / `bd list --json`. Every bd call is wrapped to
# fail silently — if Beads is unreachable, the IDs don't resolve, or any jq
# pipeline errors, the corresponding globals stay empty and truncate_to_width()
# drops the segments. The user never sees a "bd: command not found" leak into
# the statusline.
resolve_goal_phase_task() {
    # Hard prerequisite: bd + jq on PATH.
    command -v bd >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0

    # Per-instance scope resolver owns the pointer-file lookup.
    local scope_helper="$HOME/.local/bin/paperflow-active-scope"
    [ -x "$scope_helper" ] || scope_helper="$(command -v paperflow-active-scope 2>/dev/null || true)"
    [ -n "$scope_helper" ] || return 0

    local goal_id phase_id
    goal_id=$("$scope_helper" --read goal 2>/dev/null | tr -d '[:space:]')
    phase_id=$("$scope_helper" --read phase 2>/dev/null | tr -d '[:space:]')
    [ -z "$goal_id" ] && return 0
    [ -z "$phase_id" ] && return 0

    # Goal slug: pick the goal-<slug> label off the goal-task.
    local goal_json goal_slug
    goal_json=$(bd show "$goal_id" --json 2>/dev/null) || return 0
    [ -z "$goal_json" ] && return 0
    goal_slug=$(printf '%s' "$goal_json" \
        | jq -r '(.labels // [])[]? | select(startswith("goal-")) | sub("^goal-"; "")' 2>/dev/null \
        | head -n 1)
    [ -z "$goal_slug" ] && return 0

    # Phase name: pick the phase-<name> label off the phase-task.
    local phase_json phase_name
    phase_json=$(bd show "$phase_id" --json 2>/dev/null) || return 0
    [ -z "$phase_json" ] && return 0
    phase_name=$(printf '%s' "$phase_json" \
        | jq -r '(.labels // [])[]? | select(startswith("phase-")) | sub("^phase-"; "")' 2>/dev/null \
        | head -n 1)
    [ -z "$phase_name" ] && return 0

    # Goal + phase resolved — commit them to the globals.
    GOAL_SLUG="$goal_slug"
    PHASE_NAME="$phase_name"

    # Phase index/total: enumerate all phase-tasks under the goal in stable
    # creation order (id sort), find the active phase's 1-based position.
    local phase_list
    phase_list=$(bd list --label "kind:phase" --label "goal-$goal_slug" --json 2>/dev/null) || phase_list=""
    if [ -n "$phase_list" ]; then
        local phases_total phases_idx
        phases_total=$(printf '%s' "$phase_list" \
            | jq -r 'length' 2>/dev/null || echo "")
        # Position of phase_id in the list, 1-based. jq:
        phases_idx=$(printf '%s' "$phase_list" \
            | jq -r --arg pid "$phase_id" '
                [.[] | .id] | (index($pid) // empty) | . + 1
            ' 2>/dev/null || echo "")
        # Numeric guards.
        case "$phases_total" in ''|*[!0-9]*) phases_total="" ;; esac
        case "$phases_idx"   in ''|*[!0-9]*) phases_idx=""   ;; esac
        PHASE_TOTAL="${phases_total:-}"
        PHASE_INDEX="${phases_idx:-}"
    fi

    # Claimed work-task within the active phase, if any. The phase-task id
    # itself is bd-a1b2.2; its work-task children are bd-a1b2.2.* — query by
    # the phase-<name> label for portability.
    local doing_json doing_id doing_title
    doing_json=$(bd list --label "phase-$phase_name" --label "goal-$goal_slug" --status doing --json 2>/dev/null) || doing_json=""
    if [ -n "$doing_json" ]; then
        doing_id=$(printf '%s' "$doing_json" \
            | jq -r '(.[0].id // "")' 2>/dev/null || echo "")
        doing_title=$(printf '%s' "$doing_json" \
            | jq -r '(.[0].title // "")' 2>/dev/null || echo "")
        if [ -n "$doing_id" ]; then
            TASK_ID="$doing_id"
            # Truncate to ~24 chars; sanitise control bytes.
            TASK_TITLE=$(printf '%s' "$doing_title" \
                | tr -d '\000-\037\177' \
                | sed 's/[^[:print:]]//g' \
                | cut -c1-24)
        fi
    fi

    # Task progress within the active phase: total + closed.
    local phase_tasks
    phase_tasks=$(bd list --label "phase-$phase_name" --label "goal-$goal_slug" --json 2>/dev/null) || phase_tasks=""
    if [ -n "$phase_tasks" ]; then
        local t_total t_done
        t_total=$(printf '%s' "$phase_tasks" \
            | jq -r 'length' 2>/dev/null || echo "")
        t_done=$(printf '%s' "$phase_tasks" \
            | jq -r '[.[] | select(.status == "closed")] | length' 2>/dev/null || echo "")
        case "$t_total" in ''|*[!0-9]*) t_total="" ;; esac
        case "$t_done"  in ''|*[!0-9]*) t_done=""  ;; esac
        TASKS_TOTAL="${t_total:-}"
        TASKS_DONE="${t_done:-}"
    fi
}

# Truncate-aware formatting. Reads $COLUMNS or `tput cols`. Produces stdout.
truncate_to_width() {
    local cols="${COLUMNS:-}"
    if [ -z "$cols" ]; then
        cols=$(tput cols 2>/dev/null || echo 120)
    fi
    cols="${cols:-120}"
    # Numeric guard.
    case "$cols" in
        ''|*[!0-9]*) cols=120 ;;
    esac

    # Pre-compute ANSI wrappers (empty when NO_COLOR is set).
    local dim reset tcolor sep
    dim=$(ansi_dim)
    reset=$(ansi_reset)
    tcolor=$(color_for_tokens)
    sep="${dim} · ${reset}"

    local tokens_field=""
    if [ -n "$TOKENS" ]; then
        local pretty lim pct
        pretty=$(format_with_commas "$TOKENS")
        lim=$(format_limit "$LIMIT")
        pct=$(compute_percentage)
        # Colour applies only to the comma-formatted token count;
        # the limit and percentage stay un-coloured.
        tokens_field="${tcolor}${pretty}${reset} / ${lim} (${pct}%)"
    fi

    # Build cumulative line based on width.
    local out=""
    if [ -n "$tokens_field" ]; then
        out="$tokens_field"
    fi

    # SID always after tokens when width >= 40 (dimmed).
    if [ "$cols" -ge 40 ] && [ -n "$SID_SHORT" ]; then
        if [ -n "$out" ]; then
            out="${out}${sep}${dim}${SID_SHORT}${reset}"
        else
            out="${dim}${SID_SHORT}${reset}"
        fi
    fi

    # Project at >= 60 (dimmed). When a goal is active, prefer the goal slug
    # over the cwd-derived project name — same screen real estate, more useful
    # signal. Falls back to PROJECT when GOAL_SLUG is empty.
    local project_field=""
    if [ -n "$GOAL_SLUG" ]; then
        project_field="$GOAL_SLUG"
    elif [ -n "$PROJECT" ]; then
        project_field="$PROJECT"
    fi
    if [ "$cols" -ge 60 ] && [ -n "$project_field" ]; then
        if [ -n "$out" ]; then
            out="${out}${sep}${dim}${project_field}${reset}"
        else
            out="${dim}${project_field}${reset}"
        fi
    fi

    # ▸ task at >= 80 — the actionable segment. Format depends on what we
    # have: "▸ <id> <title> · <done>/<total>" full, or "▸ <done>/<total>"
    # bare when no task is claimed.
    local have_task=0
    if [ "$cols" -ge 80 ] && [ -n "$GOAL_SLUG" ]; then
        local task_field=""
        if [ -n "$TASK_ID" ]; then
            task_field="▸ ${TASK_ID}"
            [ -n "$TASK_TITLE" ] && task_field="${task_field} ${TASK_TITLE}"
            if [ -n "$TASKS_TOTAL" ]; then
                task_field="${task_field}${sep}${TASKS_DONE:-0}/${TASKS_TOTAL}"
            fi
            have_task=1
        elif [ -n "$TASKS_TOTAL" ]; then
            task_field="▸ ${TASKS_DONE:-0}/${TASKS_TOTAL}"
            have_task=1
        fi
        if [ "$have_task" = "1" ]; then
            if [ -n "$out" ]; then
                out="${out}${sep}${task_field}"
            else
                out="$task_field"
            fi
        fi
    fi

    # ▸ phase at >= 120 — full line including phase number/total + name. When
    # PHASE_INDEX/TOTAL aren't resolvable (phase-list query failed) we still
    # render "▸ phase: <name>" rather than dropping the phase entirely.
    if [ "$cols" -ge 120 ] && [ -n "$GOAL_SLUG" ] && [ -n "$PHASE_NAME" ]; then
        local phase_field=""
        if [ -n "$PHASE_INDEX" ] && [ -n "$PHASE_TOTAL" ]; then
            phase_field="▸ phase ${PHASE_INDEX}/${PHASE_TOTAL}: ${PHASE_NAME}"
        else
            phase_field="▸ phase: ${PHASE_NAME}"
        fi
        # Insert the phase BEFORE the task segment. The append-style build
        # above placed task right after project; to keep the spec's order
        # (project · phase · task · branch) we splice phase in between.
        # Easiest: rebuild from scratch with the same width gates.
        out="$tokens_field"
        if [ "$cols" -ge 40 ] && [ -n "$SID_SHORT" ]; then
            out="${out}${sep}${dim}${SID_SHORT}${reset}"
        fi
        if [ -n "$project_field" ]; then
            out="${out}${sep}${dim}${project_field}${reset}"
        fi
        out="${out}${sep}${phase_field}"
        if [ "$have_task" = "1" ]; then
            local task_field=""
            if [ -n "$TASK_ID" ]; then
                task_field="▸ ${TASK_ID}"
                [ -n "$TASK_TITLE" ] && task_field="${task_field} ${TASK_TITLE}"
                if [ -n "$TASKS_TOTAL" ]; then
                    task_field="${task_field}${sep}${TASKS_DONE:-0}/${TASKS_TOTAL}"
                fi
            elif [ -n "$TASKS_TOTAL" ]; then
                task_field="▸ ${TASKS_DONE:-0}/${TASKS_TOTAL}"
            fi
            [ -n "$task_field" ] && out="${out}${sep}${task_field}"
        fi
    fi

    # Branch at >= 80 (undimmed — secondary signal already). Always last.
    if [ "$cols" -ge 80 ] && [ -n "$BRANCH" ]; then
        if [ -n "$out" ]; then
            out="${out}${sep}${BRANCH}"
        else
            out="$BRANCH"
        fi
    fi

    printf '%s' "$out"
}

# Daily-throttled sweep + debug-log rotation.
cleanup_cache() {
    [ -d "$CACHE_DIR" ] || return 0
    local should_run=1
    if [ -e "$CLEANUP_STAMP" ]; then
        local now stamp_mtime
        now=$(date +%s 2>/dev/null || echo 0)
        stamp_mtime=$(stat -f %m "$CLEANUP_STAMP" 2>/dev/null || stat -c %Y "$CLEANUP_STAMP" 2>/dev/null || echo 0)
        if [ "$now" -gt 0 ] && [ "$stamp_mtime" -gt 0 ]; then
            local delta=$((now - stamp_mtime))
            if [ "$delta" -lt 86400 ]; then
                should_run=0
            fi
        fi
    fi
    if [ "$should_run" = "1" ]; then
        find "$CACHE_DIR" -type f -mtime +7 -delete 2>/dev/null || true
        touch "$CLEANUP_STAMP" 2>/dev/null || true
    fi

    # Debug-log rotation (>5 MB → .1).
    if [ "${STATUSLINE_DEBUG:-0}" = "1" ] && [ -e "$DEBUG_LOG" ]; then
        local size
        size=$(stat -f %z "$DEBUG_LOG" 2>/dev/null || stat -c %s "$DEBUG_LOG" 2>/dev/null || echo 0)
        if [ "${size:-0}" -gt 5242880 ]; then
            mv "$DEBUG_LOG" "$DEBUG_LOG.1" 2>/dev/null || true
        fi
    fi
}

# Pre-render cache fast-path. The Beads-mutating skills (paperflow-build /
# -plan / -review / -goal / -resume) write the formatted line to
# ~/.paperflow/statusline.txt on every claim/close/open. If that file exists
# AND its mtime is within the last $PRERENDER_MAX_AGE seconds, just cat it.
# Otherwise fall through to live composition.
#
# Returns 0 if we cat'd the cache (caller should exit), 1 to fall through.
try_prerender_cache() {
    [ -r "$PRERENDER_CACHE" ] || return 1
    local now mtime age
    now=$(date +%s 2>/dev/null) || return 1
    mtime=$(stat -f %m "$PRERENDER_CACHE" 2>/dev/null \
            || stat -c %Y "$PRERENDER_CACHE" 2>/dev/null \
            || echo "")
    [ -z "$mtime" ] && return 1
    age=$((now - mtime))
    [ "$age" -lt 0 ] && return 1
    [ "$age" -ge "$PRERENDER_MAX_AGE" ] && return 1
    # Cat the file as-is. We trust whoever wrote it (a paperflow skill) to
    # have produced safe output — no extra sanitising layer here.
    cat "$PRERENDER_CACHE" 2>/dev/null || return 1
    return 0
}

# ─── Main ───────────────────────────────────────────────────────────
main() {
    # Pre-rendered cache fast-path. We still read stdin (Claude Code pipes
    # it) so the script doesn't deadlock, but we discard it on a cache hit.
    if try_prerender_cache; then
        # Drain stdin so the caller doesn't see a SIGPIPE on close.
        cat >/dev/null 2>&1 || true
        SOURCE="cache-prerender"
        debug_log ""
        return 0
    fi

    # Stdin parse — fatal failure produces empty output.
    if ! read_stdin_json; then
        debug_log ""
        printf ''
        return 0
    fi

    # Project name from project_dir (fallback to cwd basename).
    local raw_project=""
    if [ -n "$PROJECT_DIR" ]; then
        raw_project=$(basename "$PROJECT_DIR" 2>/dev/null || echo "")
    fi
    if [ -z "$raw_project" ] && [ -n "$CWD" ]; then
        raw_project=$(basename "$CWD" 2>/dev/null || echo "")
    fi
    PROJECT=$(printf '%s' "$raw_project" | sanitise)

    cache_path
    parse_limits_cached
    get_limit
    parse_token_count
    get_branch
    resolve_goal_phase_task

    local rendered
    rendered=$(truncate_to_width)

    debug_log "$rendered"
    cleanup_cache

    printf '%s\n' "$rendered"
}

main "$@"
