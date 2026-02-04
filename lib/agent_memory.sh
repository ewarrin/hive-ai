#!/usr/bin/env bash
# Hive Agent Memory - Per-agent learning and pattern recognition
#
# Agents learn from past runs: common issues, successful patterns, gotchas

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"

# Source compatibility layer
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SCRIPT_DIR/compat.sh" 2>/dev/null || true

# Cross-platform timestamp (fallback if compat not loaded)
_timestamp() {
    if type timestamp_iso &>/dev/null; then
        timestamp_iso
    else
        date -u +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

# ============================================================================
# Agent Memory Storage
# ============================================================================

_agent_memory_file() {
    local agent="$1"
    echo "$HIVE_DIR/agent_memory/${agent}.json"
}

_global_agent_memory_file() {
    local agent="$1"
    echo "$HIVE_ROOT/agent_memory/${agent}.json"
}

# Initialize agent memory
agent_memory_init() {
    local agent="$1"
    local memory_file=$(_agent_memory_file "$agent")
    
    mkdir -p "$(dirname "$memory_file")"
    
    if [ ! -f "$memory_file" ]; then
        cat > "$memory_file" << EOF
{
  "agent": "$agent",
  "project": "$(basename "$(pwd)")",
  "created_at": "$(_timestamp)",
  "updated_at": "$(_timestamp)",
  "patterns": {
    "successful": [],
    "failed": [],
    "common_issues": [],
    "gotchas": []
  },
  "statistics": {
    "total_runs": 0,
    "successful_runs": 0,
    "average_attempts": 0,
    "common_retry_reasons": []
  },
  "learned_preferences": [],
  "file_patterns": {}
}
EOF
    fi
}

# ============================================================================
# Pattern Learning
# ============================================================================

# Record a successful pattern
# Usage: agent_memory_record_success <agent> <pattern_description> <context>
agent_memory_record_success() {
    local agent="$1"
    local pattern="$2"
    local context="$3"
    
    local memory_file=$(_agent_memory_file "$agent")
    agent_memory_init "$agent"
    
    local tmp=$(mktemp)
    jq --arg pattern "$pattern" --arg context "$context" --arg ts "$(_timestamp)" '
        .patterns.successful += [{
            pattern: $pattern,
            context: $context,
            recorded_at: $ts,
            occurrences: 1
        }] |
        .patterns.successful = (
            .patterns.successful | 
            group_by(.pattern) | 
            map({
                pattern: .[0].pattern,
                context: .[0].context,
                recorded_at: .[0].recorded_at,
                occurrences: (map(.occurrences) | add)
            }) |
            sort_by(.occurrences) | reverse | .[0:20]
        ) |
        .updated_at = $ts
    ' "$memory_file" > "$tmp" && mv "$tmp" "$memory_file"
}

# Record a failed pattern
# Usage: agent_memory_record_failure <agent> <pattern_description> <error>
agent_memory_record_failure() {
    local agent="$1"
    local pattern="$2"
    local error="$3"
    
    local memory_file=$(_agent_memory_file "$agent")
    agent_memory_init "$agent"
    
    local tmp=$(mktemp)
    jq --arg pattern "$pattern" --arg error "$error" --arg ts "$(_timestamp)" '
        .patterns.failed += [{
            pattern: $pattern,
            error: $error,
            recorded_at: $ts,
            occurrences: 1
        }] |
        .patterns.failed = (
            .patterns.failed |
            group_by(.pattern) |
            map({
                pattern: .[0].pattern,
                error: .[0].error,
                recorded_at: .[0].recorded_at,
                occurrences: (map(.occurrences) | add)
            }) |
            sort_by(.occurrences) | reverse | .[0:20]
        ) |
        .updated_at = $ts
    ' "$memory_file" > "$tmp" && mv "$tmp" "$memory_file"
}

# Record a common issue found during review
# Usage: agent_memory_record_issue <agent> <issue_type> <file_pattern> <description>
agent_memory_record_issue() {
    local agent="$1"
    local issue_type="$2"
    local file_pattern="$3"
    local description="$4"
    
    local memory_file=$(_agent_memory_file "$agent")
    agent_memory_init "$agent"
    
    local tmp=$(mktemp)
    jq --arg type "$issue_type" --arg pattern "$file_pattern" --arg desc "$description" --arg ts "$(_timestamp)" '
        .patterns.common_issues += [{
            type: $type,
            file_pattern: $pattern,
            description: $desc,
            recorded_at: $ts,
            occurrences: 1
        }] |
        .patterns.common_issues = (
            .patterns.common_issues |
            group_by(.type + .file_pattern) |
            map({
                type: .[0].type,
                file_pattern: .[0].file_pattern,
                description: .[0].description,
                recorded_at: .[0].recorded_at,
                occurrences: (map(.occurrences) | add)
            }) |
            sort_by(.occurrences) | reverse | .[0:30]
        ) |
        .updated_at = $ts
    ' "$memory_file" > "$tmp" && mv "$tmp" "$memory_file"
}

# Record a gotcha (surprising behavior in codebase)
# Usage: agent_memory_record_gotcha <agent> <gotcha>
agent_memory_record_gotcha() {
    local agent="$1"
    local gotcha="$2"
    
    local memory_file=$(_agent_memory_file "$agent")
    agent_memory_init "$agent"
    
    local tmp=$(mktemp)
    jq --arg gotcha "$gotcha" --arg ts "$(_timestamp)" '
        if (.patterns.gotchas | map(.gotcha) | index($gotcha)) then
            .
        else
            .patterns.gotchas += [{
                gotcha: $gotcha,
                recorded_at: $ts
            }] |
            .patterns.gotchas = .patterns.gotchas | .[0:20]
        end |
        .updated_at = $ts
    ' "$memory_file" > "$tmp" && mv "$tmp" "$memory_file"
}

# ============================================================================
# Statistics Tracking
# ============================================================================

# Update run statistics
# Usage: agent_memory_record_run <agent> <success:bool> <attempts:int> <retry_reason>
agent_memory_record_run() {
    local agent="$1"
    local success="$2"
    local attempts="$3"
    local retry_reason="${4:-}"
    
    local memory_file=$(_agent_memory_file "$agent")
    agent_memory_init "$agent"
    
    local tmp=$(mktemp)
    jq --argjson success "$success" --argjson attempts "$attempts" --arg reason "$retry_reason" --arg ts "$(_timestamp)" '
        .statistics.total_runs += 1 |
        .statistics.successful_runs += (if $success then 1 else 0 end) |
        .statistics.average_attempts = (
            ((.statistics.average_attempts * (.statistics.total_runs - 1)) + $attempts) / .statistics.total_runs
        ) |
        (if $reason != "" then
            .statistics.common_retry_reasons += [$reason] |
            .statistics.common_retry_reasons = (
                .statistics.common_retry_reasons |
                group_by(.) |
                map({reason: .[0], count: length}) |
                sort_by(.count) | reverse | .[0:10] |
                map(.reason)
            )
        else . end) |
        .updated_at = $ts
    ' "$memory_file" > "$tmp" && mv "$tmp" "$memory_file"
}

# ============================================================================
# File Pattern Learning
# ============================================================================

# Record that a file pattern often needs certain attention
# Usage: agent_memory_record_file_pattern <agent> <pattern> <attention_type>
agent_memory_record_file_pattern() {
    local agent="$1"
    local pattern="$2"
    local attention="$3"
    
    local memory_file=$(_agent_memory_file "$agent")
    agent_memory_init "$agent"
    
    local tmp=$(mktemp)
    jq --arg pattern "$pattern" --arg attention "$attention" --arg ts "$(_timestamp)" '
        .file_patterns[$pattern] = (.file_patterns[$pattern] // []) + [$attention] |
        .file_patterns[$pattern] = (.file_patterns[$pattern] | unique | .[0:5]) |
        .updated_at = $ts
    ' "$memory_file" > "$tmp" && mv "$tmp" "$memory_file"
}

# ============================================================================
# Context Generation
# ============================================================================

# Generate context injection for an agent based on its memory
# Usage: agent_memory_context <agent>
agent_memory_context() {
    local agent="$1"
    local memory_file=$(_agent_memory_file "$agent")
    
    if [ ! -f "$memory_file" ]; then
        return
    fi
    
    local data=$(cat "$memory_file")
    
    # Check if there's meaningful data
    local total_runs=$(echo "$data" | jq '.statistics.total_runs')
    if [ "$total_runs" -lt 2 ]; then
        return
    fi
    
    echo "## Agent Memory (Learned from Previous Runs)"
    echo ""
    
    # Common issues this agent has found before
    local common_issues=$(echo "$data" | jq -r '
        .patterns.common_issues[:5][] |
        "- **\(.type)** in `\(.file_pattern)`: \(.description) (seen \(.occurrences)x)"
    ' 2>/dev/null)
    
    if [ -n "$common_issues" ]; then
        echo "### Common Issues in This Codebase"
        echo "$common_issues"
        echo ""
    fi
    
    # Gotchas
    local gotchas=$(echo "$data" | jq -r '.patterns.gotchas[:5][].gotcha' 2>/dev/null)
    if [ -n "$gotchas" ]; then
        echo "### Gotchas to Watch For"
        echo "$gotchas" | while read -r gotcha; do
            echo "- $gotcha"
        done
        echo ""
    fi
    
    # File patterns that need attention
    local file_patterns=$(echo "$data" | jq -r '
        .file_patterns | to_entries[:5][] |
        "- `\(.key)` often needs: \(.value | join(", "))"
    ' 2>/dev/null)
    
    if [ -n "$file_patterns" ]; then
        echo "### Files That Often Need Attention"
        echo "$file_patterns"
        echo ""
    fi
    
    # Success rate context
    local success_rate=$(echo "$data" | jq '
        if .statistics.total_runs > 0 then
            (.statistics.successful_runs / .statistics.total_runs * 100 | floor)
        else 0 end
    ')
    local avg_attempts=$(echo "$data" | jq '.statistics.average_attempts | . * 10 | floor | . / 10')
    
    echo "### Statistics"
    echo "- Success rate: ${success_rate}% over $total_runs runs"
    echo "- Average attempts: $avg_attempts"
    echo ""
}

# ============================================================================
# Learning from HIVE_REPORT
# ============================================================================

# Extract learnings from a HIVE_REPORT and update memory
# Usage: agent_memory_learn_from_report <agent> <report_json> <success:bool>
agent_memory_learn_from_report() {
    local agent="$1"
    local report="$2"
    local success="$3"
    
    # Extract decisions and learn from them
    local decisions=$(echo "$report" | jq -r '.decisions[]? | "\(.decision): \(.rationale)"' 2>/dev/null)
    
    if [ -n "$decisions" ]; then
        echo "$decisions" | while read -r decision; do
            if [ "$success" = "true" ]; then
                agent_memory_record_success "$agent" "$decision" "from HIVE_REPORT"
            fi
        done
    fi
    
    # For reviewers, learn from issues found
    if [ "$agent" = "reviewer" ] || [ "$agent" = "security" ]; then
        echo "$report" | jq -r '.issues[]? | "\(.category // "general")|\(.file // "*")|\(.title)"' 2>/dev/null | while IFS='|' read -r type file title; do
            # Extract file pattern (directory + extension)
            local pattern=$(echo "$file" | sed 's|/[^/]*$|/*|' | sed 's|.*/||')
            [ -z "$pattern" ] && pattern="*"
            
            agent_memory_record_issue "$agent" "$type" "$pattern" "$title"
        done
    fi
    
    # Learn from handoff notes (often contain gotchas)
    local handoff=$(echo "$report" | jq -r '.handoff_notes // ""' 2>/dev/null)
    if [ -n "$handoff" ] && [ ${#handoff} -gt 20 ]; then
        # Only record substantial handoff notes as potential gotchas
        if echo "$handoff" | grep -qiE "gotcha|careful|note that|watch out|important|don't forget"; then
            agent_memory_record_gotcha "$agent" "${handoff:0:200}"
        fi
    fi
}

# ============================================================================
# Display
# ============================================================================

# Print agent memory summary
agent_memory_show() {
    local agent="$1"
    local memory_file=$(_agent_memory_file "$agent")
    
    if [ ! -f "$memory_file" ]; then
        echo "No memory for agent: $agent"
        return
    fi
    
    local data=$(cat "$memory_file")
    
    echo ""
    echo -e "\033[1mAgent Memory: $agent\033[0m"
    echo -e "\033[2m─────────────────────────────────────────\033[0m"
    echo ""
    
    # Stats
    local total=$(echo "$data" | jq '.statistics.total_runs')
    local success=$(echo "$data" | jq '.statistics.successful_runs')
    local avg=$(echo "$data" | jq '.statistics.average_attempts | . * 10 | floor | . / 10')
    
    echo -e "\033[1mStatistics:\033[0m"
    echo "  Runs: $total (${success} successful)"
    echo "  Avg attempts: $avg"
    echo ""
    
    # Common issues
    local issues=$(echo "$data" | jq -r '.patterns.common_issues[:5][] | "  - [\(.type)] \(.description) (\(.occurrences)x)"' 2>/dev/null)
    if [ -n "$issues" ]; then
        echo -e "\033[1mCommon Issues:\033[0m"
        echo "$issues"
        echo ""
    fi
    
    # Gotchas
    local gotchas=$(echo "$data" | jq -r '.patterns.gotchas[:3][].gotcha' 2>/dev/null)
    if [ -n "$gotchas" ]; then
        echo -e "\033[1mGotchas:\033[0m"
        echo "$gotchas" | while read -r g; do
            echo "  - ${g:0:80}..."
        done
        echo ""
    fi
}

# ============================================================================
# Warning Context Generation
# ============================================================================

# Get warning context for an agent based on past patterns
# Used to inject warnings into agent prompts based on learned patterns
agent_memory_get_warnings() {
    local agent="$1"

    # Check project memory for agent patterns
    local patterns=$(memory_read 2>/dev/null | jq -r --arg a "$agent" '.agent_patterns[$a] // empty' 2>/dev/null)

    [ -z "$patterns" ] && return

    local challenge_rate=$(echo "$patterns" | jq -r '.challenge_rate // 0')
    local avg_confidence=$(echo "$patterns" | jq -r '.avg_confidence // 0')

    # Also check agent-specific memory for common issues
    local memory_file=$(_agent_memory_file "$agent")
    local common_issues=""
    if [ -f "$memory_file" ]; then
        common_issues=$(jq -r '.patterns.common_issues[:3][] | "- \(.type): \(.description)"' "$memory_file" 2>/dev/null)
    fi

    local warnings=""

    # Warn if high challenge rate
    if [ "$(echo "$challenge_rate > 0.3" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
        warnings="$warnings
- Your work has been challenged frequently. Double-check your output."
    fi

    # Warn if low confidence historically
    if [ "$(echo "$avg_confidence < 0.7 && $avg_confidence > 0" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
        warnings="$warnings
- Historical confidence is low. Be thorough and explicit."
    fi

    # Add common issues
    if [ -n "$common_issues" ]; then
        warnings="$warnings
Based on previous runs, watch out for:
$common_issues"
    fi

    [ -n "$warnings" ] && echo "$warnings"
}

# ============================================================================
# Cleanup
# ============================================================================

# Reset agent memory
agent_memory_reset() {
    local agent="$1"
    local memory_file=$(_agent_memory_file "$agent")
    
    rm -f "$memory_file"
    agent_memory_init "$agent"
    
    echo "Reset memory for: $agent"
}

# Reset all agent memories
agent_memory_reset_all() {
    rm -rf "$HIVE_DIR/agent_memory"
    mkdir -p "$HIVE_DIR/agent_memory"
    echo "Reset all agent memories"
}
