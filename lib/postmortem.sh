#!/usr/bin/env bash
# Hive Post-Mortem - Auto-generate run summary reports
#
# After a workflow completes, generates a markdown report with:
# - What was built
# - Agent performance stats
# - Issues found
# - Time breakdown
# - Remaining work

HIVE_DIR="${HIVE_DIR:-.hive}"

# ============================================================================
# Report Generation
# ============================================================================

# Generate a post-mortem report for a completed run
postmortem_generate() {
    local run_id="$1"
    local epic_id="$2"
    
    local report_dir="$HIVE_DIR/runs/$run_id"
    local report_file="$report_dir/report.md"
    local events_file="$HIVE_DIR/events.jsonl"
    local scratchpad_file="$HIVE_DIR/scratchpad.json"
    
    mkdir -p "$report_dir"
    
    # Gather data
    local objective=""
    local start_time=""
    local end_time=""
    
    if [ -f "$scratchpad_file" ]; then
        objective=$(jq -r '.objective // "Unknown"' "$scratchpad_file")
    fi
    
    if [ -f "$events_file" ]; then
        start_time=$(grep "\"run_start\"" "$events_file" | grep "$run_id" | jq -r '.ts' | head -1)
        end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    fi
    
    # Calculate duration
    local duration="unknown"
    if [ -n "$start_time" ]; then
        local start_epoch=$(date -d "$start_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +%s 2>/dev/null || echo "0")
        local end_epoch=$(date +%s)
        if [ "$start_epoch" -gt 0 ] 2>/dev/null; then
            local diff=$((end_epoch - start_epoch))
            local mins=$((diff / 60))
            local secs=$((diff % 60))
            duration="${mins}m ${secs}s"
        fi
    fi
    
    # Count agents and attempts
    local agent_stats=""
    if [ -f "$events_file" ]; then
        agent_stats=$(grep '"agent_complete"' "$events_file" 2>/dev/null | jq -s '
            group_by(.agent) | map({
                agent: .[0].agent,
                total_attempts: length,
                successes: [.[] | select(.success == true)] | length,
                failures: [.[] | select(.success != true)] | length
            })
        ' 2>/dev/null || echo "[]")
    fi
    
    # Get self-eval stats
    local selfeval_stats=""
    if [ -f "$events_file" ]; then
        selfeval_stats=$(grep '"agent_selfeval"' "$events_file" 2>/dev/null | jq -s '
            map({agent, status, confidence: (.confidence // 0)})
        ' 2>/dev/null || echo "[]")
    fi
    
    # Get Beads task status
    local beads_summary=""
    if command -v bd &>/dev/null; then
        local total=$(bd list --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        local closed=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "closed")] | length' 2>/dev/null || echo "0")
        local open=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "open" or .status == "ready")] | length' 2>/dev/null || echo "0")
        local blocked=$(bd list --json 2>/dev/null | jq '[.[] | select(.priority == 0 and .status != "closed")] | length' 2>/dev/null || echo "0")
        beads_summary="Total: $total | Closed: $closed | Open: $open | Blockers: $blocked"
    fi
    
    # Get validation stats
    local validation_passes=0
    local validation_fails=0
    if [ -f "$events_file" ]; then
        validation_passes=$(grep -c '"validation_pass"' "$events_file" 2>/dev/null || echo "0")
        validation_fails=$(grep -c '"validation_fail"' "$events_file" 2>/dev/null || echo "0")
    fi
    
    # Get decisions
    local decisions=""
    if [ -f "$scratchpad_file" ]; then
        decisions=$(jq -r '.decisions[] | "- **\(.decision)** — \(.rationale // "no rationale")"' "$scratchpad_file" 2>/dev/null || echo "")
    fi
    
    # Get files modified (from selfeval events)
    local files_modified=""
    if [ -f "$events_file" ]; then
        files_modified=$(grep '"agent_selfeval"' "$events_file" 2>/dev/null | jq -r '.files_modified // 0' | paste -sd+ | bc 2>/dev/null || echo "0")
    fi
    
    # Get git diff stats if in a git repo
    local git_stats=""
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        git_stats=$(git diff --stat HEAD 2>/dev/null | tail -1 || echo "")
        if [ -z "$git_stats" ]; then
            git_stats=$(git diff --stat 2>/dev/null | tail -1 || echo "")
        fi
    fi
    
    # Get error/blocker summary
    local blockers=""
    if [ -f "$scratchpad_file" ]; then
        blockers=$(jq -r '.blockers[] | "- [\(.status)] \(.blocker) (filed by \(.agent))"' "$scratchpad_file" 2>/dev/null || echo "")
    fi
    
    # Build report
    cat > "$report_file" << REPORT
# Hive Run Report

**Run ID:** $run_id
**Epic:** $epic_id
**Objective:** $objective
**Duration:** $duration
**Date:** $(date -u +"%Y-%m-%d %H:%M UTC")

---

## Summary

| Metric | Value |
|--------|-------|
| Tasks | $beads_summary |
| Validations | ✓ $validation_passes passed, ✗ $validation_fails failed |
| Git Changes | ${git_stats:-no changes detected} |

## Agent Performance

| Agent | Attempts | Success | Failed |
|-------|----------|---------|--------|
$(echo "$agent_stats" | jq -r '.[] | "| \(.agent) | \(.total_attempts) | \(.successes) | \(.failures) |"' 2>/dev/null || echo "| (no data) | - | - | - |")

REPORT

    # Add self-eval section if we have data
    if [ "$selfeval_stats" != "[]" ] && [ -n "$selfeval_stats" ]; then
        cat >> "$report_file" << REPORT
## Agent Self-Assessments

| Agent | Status | Confidence |
|-------|--------|------------|
$(echo "$selfeval_stats" | jq -r '.[] | "| \(.agent) | \(.status) | \(.confidence) |"' 2>/dev/null || echo "| (no data) | - | - |")

REPORT
    fi
    
    # Add decisions
    if [ -n "$decisions" ]; then
        cat >> "$report_file" << REPORT
## Key Decisions

$decisions

REPORT
    fi
    
    # Add blockers
    if [ -n "$blockers" ]; then
        cat >> "$report_file" << REPORT
## Blockers & Issues

$blockers

REPORT
    fi
    
    # Add remaining work
    if command -v bd &>/dev/null; then
        local open_tasks=$(bd list --json 2>/dev/null | jq -r '.[] | select(.status == "open" or .status == "ready") | "- [\(.id)] \(.title) (P\(.priority // "?"))"' 2>/dev/null || echo "")
        if [ -n "$open_tasks" ]; then
            cat >> "$report_file" << REPORT
## Remaining Work

$open_tasks

REPORT
        fi
    fi
    
    # Add event timeline (last 20 events)
    if [ -f "$events_file" ]; then
        cat >> "$report_file" << REPORT
## Event Timeline

\`\`\`
$(tail -20 "$events_file" | jq -r '"\(.ts) [\(.event)] \(.agent // "") \(.summary // .error // .check // "")"' 2>/dev/null || echo "no events")
\`\`\`

REPORT
    fi
    
    cat >> "$report_file" << REPORT
---
*Generated by Hive v1.0*
REPORT
    
    echo "$report_file"
}

# Print a compact post-mortem to terminal
postmortem_print_summary() {
    local run_id="$1"
    local epic_id="$2"
    
    local events_file="$HIVE_DIR/events.jsonl"
    
    # Agent stats
    if [ -f "$events_file" ]; then
        local agents=$(grep '"agent_complete"' "$events_file" 2>/dev/null | jq -s '
            group_by(.agent) | map("\(.[0].agent): \([.[] | select(.success == true)] | length)/\(length) passed") | .[]
        ' -r 2>/dev/null)
        
        if [ -n "$agents" ]; then
            echo "$agents" | while read -r line; do
                echo "  $line"
            done
        fi
    fi
    
    # Beads stats
    if command -v bd &>/dev/null; then
        local closed=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "closed")] | length' 2>/dev/null || echo "0")
        local open=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "open" or .status == "ready")] | length' 2>/dev/null || echo "0")
        echo "  Tasks: $closed closed, $open remaining"
    fi
}
