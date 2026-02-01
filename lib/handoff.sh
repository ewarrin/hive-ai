#!/usr/bin/env bash
# Hive Handoff - Structured documents for agent-to-agent communication

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
HANDOFFS_DIR="$HIVE_DIR/handoffs"

# ============================================================================
# Core Functions
# ============================================================================

# Get the next sequence number for a handoff
handoff_next_seq() {
    local from="$1"
    local to="$2"
    
    mkdir -p "$HANDOFFS_DIR"
    
    local count=$(ls -1 "$HANDOFFS_DIR/${from}-to-${to}-"*.json 2>/dev/null | wc -l)
    printf "%03d" $((count + 1))
}

# Create a new handoff document
handoff_create() {
    local from_agent="$1"
    local to_agent="$2"
    local summary="$3"
    local tasks_json="${4:-[]}"
    local decisions_json="${5:-[]}"
    local context_json="${6:-{}}"
    local expectations_json="${7:-[]}"
    local success_criteria_json="${8:-[]}"
    
    # Validate JSON args - default if invalid
    echo "$tasks_json" | jq . >/dev/null 2>&1 || tasks_json="[]"
    echo "$decisions_json" | jq . >/dev/null 2>&1 || decisions_json="[]"
    echo "$context_json" | jq . >/dev/null 2>&1 || context_json="{}"
    echo "$expectations_json" | jq . >/dev/null 2>&1 || expectations_json="[]"
    echo "$success_criteria_json" | jq . >/dev/null 2>&1 || success_criteria_json="[]"
    
    mkdir -p "$HANDOFFS_DIR"
    
    local seq=$(handoff_next_seq "$from_agent" "$to_agent")
    local handoff_id="${from_agent}-to-${to_agent}-${seq}"
    local handoff_file="$HANDOFFS_DIR/${handoff_id}.json"
    
    local handoff=$(jq -n \
        --arg id "$handoff_id" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg from "$from_agent" \
        --arg to "$to_agent" \
        --arg summary "$summary" \
        --argjson tasks "$tasks_json" \
        --argjson decisions "$decisions_json" \
        --argjson context "$context_json" \
        --argjson expectations "$expectations_json" \
        --argjson success_criteria "$success_criteria_json" \
        '{
            handoff_id: $id,
            created_at: $ts,
            from_agent: $from,
            to_agent: $to,
            summary: $summary,
            tasks: $tasks,
            decisions: $decisions,
            context: $context,
            expectations: $expectations,
            success_criteria: $success_criteria,
            status: "pending",
            received_at: null,
            completed_at: null
        }'
    )
    
    echo "$handoff" > "$handoff_file"
    
    # Log the handoff
    if type log_handoff_created &>/dev/null; then
        log_handoff_created "$from_agent" "$to_agent" "$handoff_file"
    fi
    
    echo "$handoff_id"
}

# Read a handoff document
handoff_read() {
    local handoff_id="$1"
    local handoff_file="$HANDOFFS_DIR/${handoff_id}.json"
    
    if [ -f "$handoff_file" ]; then
        cat "$handoff_file"
    else
        echo "Handoff not found: $handoff_id" >&2
        return 1
    fi
}

# Mark handoff as received by the target agent
handoff_mark_received() {
    local handoff_id="$1"
    local handoff_file="$HANDOFFS_DIR/${handoff_id}.json"
    
    if [ -f "$handoff_file" ]; then
        local current=$(cat "$handoff_file")
        echo "$current" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '.status = "in_progress" | .received_at = $ts' > "$handoff_file"
    fi
}

# Mark handoff as completed
handoff_mark_complete() {
    local handoff_id="$1"
    local results_json="${2:-{}}"
    local handoff_file="$HANDOFFS_DIR/${handoff_id}.json"
    
    if [ -f "$handoff_file" ]; then
        local current=$(cat "$handoff_file")
        echo "$current" | jq \
            --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --argjson results "$results_json" \
            '.status = "complete" | .completed_at = $ts | .results = $results' > "$handoff_file"
    fi
}

# Get the latest handoff for an agent
handoff_latest_for() {
    local agent="$1"
    
    local latest=$(ls -1t "$HANDOFFS_DIR"/*-to-${agent}-*.json 2>/dev/null | head -1)
    if [ -n "$latest" ] && [ -f "$latest" ]; then
        basename "$latest" .json
    fi
}

# Get all pending handoffs for an agent
handoff_pending_for() {
    local agent="$1"
    
    local pending="[]"
    for file in "$HANDOFFS_DIR"/*-to-${agent}-*.json; do
        if [ -f "$file" ]; then
            local status=$(jq -r '.status' "$file")
            if [ "$status" == "pending" ]; then
                local id=$(jq -r '.handoff_id' "$file")
                pending=$(echo "$pending" | jq --arg id "$id" '. += [$id]')
            fi
        fi
    done
    
    echo "$pending"
}

# ============================================================================
# Handoff Builders for Common Scenarios
# ============================================================================

# Build handoff from architect to implementer
handoff_architect_to_implementer() {
    local summary="$1"
    local epic_id="$2"
    
    # Get tasks from Beads
    local tasks="[]"
    if command -v bd &>/dev/null && [ -n "$epic_id" ]; then
        tasks=$(bd list --json 2>/dev/null | jq '[.[] | {
            beads_id: .id,
            title: .title,
            priority: .priority,
            status: .status,
            type: .type
        }]' || echo "[]")
    fi
    
    # Get decisions from scratchpad
    local decisions="[]"
    if [ -f "$HIVE_DIR/scratchpad.json" ]; then
        decisions=$(jq '[(.decisions // [])[] | select(type == "object") | {decision: (.decision // ""), rationale: (.rationale // "")}]' "$HIVE_DIR/scratchpad.json" 2>/dev/null || echo "[]")
    fi
    
    # Get context from scratchpad
    local context="{}"
    if [ -f "$HIVE_DIR/scratchpad.json" ]; then
        context=$(jq '.context // {}' "$HIVE_DIR/scratchpad.json" 2>/dev/null || echo "{}")
    fi
    
    local expectations='[
        "All code should compile without errors",
        "Follow existing patterns in the codebase",
        "Use design system components where applicable",
        "Update Beads task status (in_progress -> closed)"
    ]'
    
    local success_criteria='[
        "npm run build passes (or equivalent)",
        "All assigned tasks in Beads are closed",
        "No new lint errors introduced"
    ]'
    
    handoff_create "architect" "implementer" "$summary" "$tasks" "$decisions" "$context" "$expectations" "$success_criteria"
}

# Build handoff from implementer to tester
handoff_implementer_to_tester() {
    local summary="$1"
    local files_modified="$2"  # JSON array
    local epic_id="$3"
    
    # Build tasks for testing
    local tasks=$(echo "$files_modified" | jq '[.[] | {
        type: "test",
        file: .,
        action: "write tests for this file"
    }]')
    
    # Get context
    local context="{}"
    if [ -f "$HIVE_DIR/scratchpad.json" ]; then
        local valid_files="[]"
        echo "$files_modified" | jq . >/dev/null 2>&1 && valid_files="$files_modified"
        context=$(jq --argjson files "$valid_files" '(.context // {}) + {files_modified: $files}' "$HIVE_DIR/scratchpad.json" 2>/dev/null || echo "{}")
    fi
    
    local expectations='[
        "Write unit tests for new functionality",
        "Write integration tests for workflows",
        "Achieve reasonable test coverage",
        "All tests should pass"
    ]'
    
    local success_criteria='[
        "Test suite passes",
        "No decrease in coverage",
        "Edge cases are tested"
    ]'
    
    handoff_create "implementer" "tester" "$summary" "$tasks" "[]" "$context" "$expectations" "$success_criteria"
}

# Build handoff from implementer to ui-designer
handoff_implementer_to_ui_designer() {
    local summary="$1"
    local files_modified="$2"  # JSON array
    local epic_id="$3"
    
    # Filter to UI files
    local ui_files=$(echo "$files_modified" | jq '[.[] | select(
        contains(".vue") or 
        contains(".tsx") or 
        contains(".jsx") or
        contains("/pages/") or
        contains("/components/")
    )]')
    
    local tasks=$(echo "$ui_files" | jq '[.[] | {
        type: "ui_review",
        file: .,
        action: "review and improve UI quality"
    }]')
    
    local context="{}"
    if [ -f "$HIVE_DIR/scratchpad.json" ]; then
        context=$(jq '.context' "$HIVE_DIR/scratchpad.json")
    fi
    
    local expectations='[
        "Ensure design system consistency",
        "Fix spacing, typography, color issues",
        "Add missing states (loading, empty, error)",
        "Ensure responsive design works",
        "Ensure dark mode works"
    ]'
    
    local success_criteria='[
        "UI looks polished and professional",
        "Consistent use of design system components",
        "Responsive on mobile, tablet, desktop",
        "All interactive elements have proper states"
    ]'
    
    handoff_create "implementer" "ui-designer" "$summary" "$tasks" "[]" "$context" "$expectations" "$success_criteria"
}

# Build handoff to debugger on failure
handoff_to_debugger() {
    local from_agent="$1"
    local error="$2"
    local context_json="$3"
    
    local tasks=$(jq -n --arg error "$error" '[{
        type: "debug",
        error: $error,
        action: "diagnose and fix"
    }]')
    
    local expectations='[
        "Diagnose the root cause",
        "Implement minimal fix",
        "Verify the fix works",
        "Document findings"
    ]'
    
    local success_criteria='[
        "Error no longer occurs",
        "Build passes",
        "No regressions introduced"
    ]'
    
    handoff_create "$from_agent" "debugger" "Fix error: $error" "$tasks" "[]" "$context_json" "$expectations" "$success_criteria"
}

# ============================================================================
# Formatting for Agent Consumption
# ============================================================================

# Format handoff as markdown for inclusion in agent prompt
handoff_to_markdown() {
    local handoff_id="$1"
    local handoff=$(handoff_read "$handoff_id")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    echo "$handoff" | jq -r '
        "## Handoff from \(.from_agent)\n\n" +
        "**Summary:** \(.summary)\n\n" +
        "### Tasks\n\n" +
        (.tasks | map("- **\(.title // .file // .action)** (Priority: \(.priority // "N/A"), Status: \(.status // "pending"))") | join("\n")) +
        "\n\n### Decisions Made\n\n" +
        (.decisions | map("- \(.decision)" + if .rationale != "" then " (\(.rationale))" else "" end) | join("\n")) +
        "\n\n### Context\n\n```json\n" +
        (.context | tojson) +
        "\n```\n\n### Expectations\n\n" +
        (.expectations | map("- \(.)") | join("\n")) +
        "\n\n### Success Criteria\n\n" +
        (.success_criteria | map("- \(.)") | join("\n"))
    '
}
