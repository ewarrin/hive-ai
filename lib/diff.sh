#!/usr/bin/env bash
# Hive Diff Tracker - Capture and provide diffs between phases
#
# Takes snapshots of git state at phase boundaries so that
# reviewers and testers know exactly what changed.

HIVE_DIR="${HIVE_DIR:-.hive}"

# ============================================================================
# Snapshot Management
# ============================================================================

# Save current git state as a named snapshot
diff_snapshot() {
    local name="$1"  # e.g., "before_implementation", "after_implementation"
    local run_id="$2"
    
    local snapshot_dir="$HIVE_DIR/runs/$run_id/snapshots"
    mkdir -p "$snapshot_dir"
    
    if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        # Not a git repo - just save file listing
        find . -type f \
            ! -path './.git/*' \
            ! -path './.hive/*' \
            ! -path './.beads/*' \
            ! -path './node_modules/*' \
            ! -path './.nuxt/*' \
            ! -path './.output/*' \
            ! -path './dist/*' \
            | sort > "$snapshot_dir/${name}.files"
        echo "$snapshot_dir/${name}.files"
        return
    fi
    
    # Save git ref
    local ref=$(git rev-parse HEAD 2>/dev/null || echo "none")
    echo "$ref" > "$snapshot_dir/${name}.ref"
    
    # Save staged + unstaged diff against HEAD
    git diff HEAD > "$snapshot_dir/${name}.diff" 2>/dev/null || true
    
    # Save file listing
    git diff --name-only HEAD > "$snapshot_dir/${name}.files" 2>/dev/null || true
    
    # Save stat
    git diff --stat HEAD > "$snapshot_dir/${name}.stat" 2>/dev/null || true
    
    echo "$snapshot_dir/${name}.ref"
}

# Get diff between two snapshots
diff_between() {
    local from_name="$1"
    local to_name="$2"
    local run_id="$3"
    
    local snapshot_dir="$HIVE_DIR/runs/$run_id/snapshots"
    
    if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        # Compare file listings
        if [ -f "$snapshot_dir/${from_name}.files" ] && [ -f "$snapshot_dir/${to_name}.files" ]; then
            diff "$snapshot_dir/${from_name}.files" "$snapshot_dir/${to_name}.files" || true
        fi
        return
    fi
    
    local from_ref=$(cat "$snapshot_dir/${from_name}.ref" 2>/dev/null || echo "")
    local to_ref=$(cat "$snapshot_dir/${to_name}.ref" 2>/dev/null || echo "")
    
    if [ -n "$from_ref" ] && [ -n "$to_ref" ] && [ "$from_ref" != "none" ] && [ "$to_ref" != "none" ]; then
        git diff "$from_ref" "$to_ref" 2>/dev/null
    else
        # Fall back to comparing saved diffs
        echo "# Changes in $to_name (compared to $from_name)"
        if [ -f "$snapshot_dir/${to_name}.diff" ]; then
            cat "$snapshot_dir/${to_name}.diff"
        fi
    fi
}

# Get current diff (working tree changes)
diff_current() {
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        git diff HEAD 2>/dev/null
    else
        echo "# Not a git repository"
    fi
}

# Get a summary of current changes (stat format)
diff_current_stat() {
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        git diff --stat HEAD 2>/dev/null
    else
        echo "# Not a git repository"
    fi
}

# Get list of changed files
diff_changed_files() {
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        git diff --name-only HEAD 2>/dev/null
    else
        echo ""
    fi
}

# ============================================================================
# Diff Context for Agents
# ============================================================================

# Generate a diff context block suitable for including in agent prompts
diff_context_for_agent() {
    local run_id="$1"
    local phase="$2"  # e.g., "after_implementation"
    
    local snapshot_dir="$HIVE_DIR/runs/$run_id/snapshots"
    
    # Get stat of current changes
    local stat=$(diff_current_stat)
    local files=$(diff_changed_files)
    
    if [ -z "$stat" ] || [ "$stat" == "# Not a git repository" ]; then
        echo ""
        return
    fi
    
    local context="## Changes Since Last Phase

### Files Modified
\`\`\`
$files
\`\`\`

### Change Summary
\`\`\`
$stat
\`\`\`"

    # Add actual diff (truncated) for reviewers
    local diff=$(diff_current | head -500)
    local diff_lines=$(diff_current | wc -l)
    
    if [ "$diff_lines" -gt 0 ]; then
        context="$context

### Diff (${diff_lines} lines total)
\`\`\`diff
$diff"
        
        if [ "$diff_lines" -gt 500 ]; then
            context="$context
... (truncated, $((diff_lines - 500)) more lines)"
        fi
        
        context="$context
\`\`\`"
    fi
    
    echo "$context"
}

# Generate focused diff for specific files (for targeted review)
diff_for_files() {
    local files_json="$1"  # JSON array of file paths
    
    if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        echo ""
        return
    fi
    
    echo "$files_json" | jq -r '.[]' | while read -r file; do
        if [ -n "$file" ] && [ -f "$file" ]; then
            local file_diff=$(git diff HEAD -- "$file" 2>/dev/null)
            if [ -n "$file_diff" ]; then
                echo "### $file"
                echo '```diff'
                echo "$file_diff" | head -100
                echo '```'
                echo ""
            fi
        fi
    done
}
