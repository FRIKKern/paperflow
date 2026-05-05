#!/usr/bin/env bash
# Fail CI if paperflow's skill set exceeds the 6-skill cap, or if any
# skill is nested inside another. Spec v7 § "CI enforcement" makes the
# cap a hard rule: a 7th skill must displace an existing one in the
# same PR — never additive. Nested skill subdirectories are forbidden
# so the cap stays honest (a folded-in mini-skill still counts).

set -eu

# Run from the repo root regardless of where this is invoked from.
cd "$(dirname "$0")/.."

CAP=6

count="$(find skills -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$count" -gt "$CAP" ]; then
    echo "✗ paperflow skills exceeded cap: $count > $CAP" >&2
    echo "  files:" >&2
    find skills -name '*.md' -type f >&2
    echo "" >&2
    echo "  A 7th skill must displace one of the existing 6. See spec v7 §CI enforcement." >&2
    exit 1
fi

nested="$(find skills -mindepth 2 -type d 2>/dev/null || true)"
if [ -n "$nested" ]; then
    echo "✗ paperflow skill nesting forbidden:" >&2
    echo "$nested" | sed 's/^/    /' >&2
    exit 1
fi

echo "✓ skills: $count / $CAP, no nesting"
