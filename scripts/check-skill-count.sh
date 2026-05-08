#!/usr/bin/env bash
# Fail CI if paperflow's skill set exceeds the 7-skill cap, or if any
# skill is nested inside another. The cap covers the six lifecycle skills
# (goal, plan, build, review, install, resume) plus the plugin
# `bootstrap` skill that runs install.sh after `/plugin install paperflow`.
# An 8th skill must displace an existing one in the same PR — never
# additive. Nested skill subdirectories are forbidden so the cap stays
# honest (a folded-in mini-skill still counts).

set -eu

# Run from the repo root regardless of where this is invoked from.
cd "$(dirname "$0")/.."

CAP=7

count="$(find skills -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$count" -gt "$CAP" ]; then
    echo "✗ paperflow skills exceeded cap: $count > $CAP" >&2
    echo "  files:" >&2
    find skills -name '*.md' -type f >&2
    echo "" >&2
    echo "  An 8th skill must displace one of the existing 7. See spec v7 §CI enforcement." >&2
    exit 1
fi

nested="$(find skills -mindepth 2 -type d 2>/dev/null || true)"
if [ -n "$nested" ]; then
    echo "✗ paperflow skill nesting forbidden:" >&2
    echo "$nested" | sed 's/^/    /' >&2
    exit 1
fi

echo "✓ skills: $count / $CAP, no nesting"
