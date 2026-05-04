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

    local tokens_field=""
    if [ -n "$TOKENS" ]; then
        local pretty
        pretty=$(format_with_commas "$TOKENS")
        local lim
        lim=$(format_limit "$LIMIT")
        tokens_field="$pretty / $lim"
    fi

    # Build cumulative line based on width.
    local out=""
    if [ -n "$tokens_field" ]; then
        out="$tokens_field"
    fi

    # SID always after tokens when width >= 40.
    if [ "$cols" -ge 40 ] && [ -n "$SID_SHORT" ]; then
        if [ -n "$out" ]; then
            out="$out · $SID_SHORT"
        else
            out="$SID_SHORT"
        fi
    fi

    # Project at >= 60.
    if [ "$cols" -ge 60 ] && [ -n "$PROJECT" ]; then
        if [ -n "$out" ]; then
            out="$out · $PROJECT"
        else
            out="$PROJECT"
        fi
    fi

    # Branch at >= 80.
    if [ "$cols" -ge 80 ] && [ -n "$BRANCH" ]; then
        if [ -n "$out" ]; then
            out="$out · $BRANCH"
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

# ─── Main ───────────────────────────────────────────────────────────
main() {
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

    local rendered
    rendered=$(truncate_to_width)

    debug_log "$rendered"
    cleanup_cache

    printf '%s\n' "$rendered"
}

main "$@"
