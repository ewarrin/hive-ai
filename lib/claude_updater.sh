#!/usr/bin/env bash
# Hive CLAUDE.md Updater - Append learnings from runs
#
# Extracts key learnings from completed runs and appends them to CLAUDE.md
# so future runs benefit from accumulated knowledge.

HIVE_DIR="${HIVE_DIR:-.hive}"

# ============================================================================
# Core Functions
# ============================================================================

# Update CLAUDE.md with learnings from a completed run
update_claude_md_from_run() {
    local run_id="$1"
    local epic_id="$2"

    # Skip if no CLAUDE.md exists (user hasn't opted in)
    [ ! -f "CLAUDE.md" ] && return 0

    local learnings=""
    local run_dir="$HIVE_DIR/runs/$run_id"

    # 1. Collect decisions from scratchpad
    local decisions=""
    local sp_file="$run_dir/scratchpad_final.json"
    [ ! -f "$sp_file" ] && sp_file="$HIVE_DIR/scratchpad.json"

    if [ -f "$sp_file" ]; then
        decisions=$(jq -r '
            .decisions[]? |
            "- **\(.agent // "agent")**: \(.decision)" +
            (if .rationale != null and .rationale != "" then " (\(.rationale))" else "" end)
        ' "$sp_file" 2>/dev/null | head -10)
    fi

    # 2. Collect important findings from reviewer
    local findings=""
    local reviewer_file=$(find "$run_dir/output" -name "reviewer*.md" -o -name "reviewer*.txt" 2>/dev/null | head -1)

    if [ -f "$reviewer_file" ]; then
        findings=$(grep -E "BLOCKING|CRITICAL|IMPORTANT|WARNING" "$reviewer_file" 2>/dev/null | head -5 | sed 's/^/- /')
    fi

    # 3. Collect resolved challenges (patterns to remember)
    local challenges=""
    if [ -f "$HIVE_DIR/memory.json" ]; then
        challenges=$(jq -r '
            [(.challenge_history // [])[-5:][]] |
            map("- \(.from) challenged \(.to): \(.category)") | .[]' "$HIVE_DIR/memory.json" 2>/dev/null)
    fi

    # 4. Collect gotchas discovered
    local gotchas=""
    if [ -f "$HIVE_DIR/memory.json" ]; then
        gotchas=$(jq -r '.gotchas[-5:]? | .[]? | "- \(.)"' "$HIVE_DIR/memory.json" 2>/dev/null)
    fi

    # Build learnings section
    [ -n "$decisions" ] && learnings="$learnings
### Decisions
$decisions"

    [ -n "$findings" ] && learnings="$learnings
### Review Findings
$findings"

    [ -n "$challenges" ] && learnings="$learnings
### Challenge Patterns
$challenges"

    [ -n "$gotchas" ] && learnings="$learnings
### Gotchas
$gotchas"

    # Only append if there's something meaningful
    if [ -n "$learnings" ]; then
        # Check if this run's learnings are already in CLAUDE.md
        if grep -q "Run $run_id" CLAUDE.md 2>/dev/null; then
            return 0  # Already recorded
        fi

        local date=$(date +%Y-%m-%d)
        echo "" >> CLAUDE.md
        echo "## Hive Learnings (Run $run_id, $date)" >> CLAUDE.md
        echo "$learnings" >> CLAUDE.md
    fi
}

# Prune old learnings to keep CLAUDE.md manageable
prune_claude_md_learnings() {
    local max_sections="${1:-${HIVE_CLAUDE_MD_MAX_SECTIONS:-10}}"

    [ ! -f "CLAUDE.md" ] && return 0

    # Count Hive Learnings sections
    local count=$(grep -c "^## Hive Learnings" CLAUDE.md 2>/dev/null || echo "0")

    if [ "$count" -gt "$max_sections" ]; then
        echo "Note: CLAUDE.md has $count Hive Learnings sections. Consider pruning older ones."
        echo "  Oldest sections should be manually removed to keep file size manageable."
    fi
}

# ============================================================================
# Export Functions
# ============================================================================

# Make functions available when sourced
export -f update_claude_md_from_run 2>/dev/null || true
export -f prune_claude_md_learnings 2>/dev/null || true
