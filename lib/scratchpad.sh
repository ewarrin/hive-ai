#!/usr/bin/env bash
# Hive Scratchpad - Shared agent memory

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
SCRATCHPAD_FILE="$HIVE_DIR/scratchpad.json"

# ============================================================================
# Core Functions
# ============================================================================

# Initialize a new scratchpad
# Usage: scratchpad_init <run_id> <epic_id> <objective> [trace_id]
scratchpad_init() {
    local run_id="$1"
    local epic_id="$2"
    local objective="$3"
    local trace_id="${4:-}"

    mkdir -p "$HIVE_DIR"

    local scratchpad=$(jq -n \
        --arg run_id "$run_id" \
        --arg epic_id "$epic_id" \
        --arg objective "$objective" \
        --arg trace_id "$trace_id" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            run_id: $run_id,
            epic_id: $epic_id,
            objective: $objective,
            trace_id: (if $trace_id != "" then $trace_id else null end),
            current_span_id: null,
            status: "in_progress",
            created_at: $ts,
            updated_at: $ts,
            current_phase: "init",
            current_agent: null,
            decisions: [],
            blockers: [],
            context: {
                tech_stack: [],
                key_files: [],
                patterns_established: []
            },
            iteration: {
                phase: null,
                attempt: 0,
                max_attempts: 3,
                history: []
            },
            completed_agents: [],
            pending_tasks: [],
            completed_tasks: [],
            nested_workflows: []
        }'
    )

    echo "$scratchpad" > "$SCRATCHPAD_FILE"

    # Export for child processes
    if [ -n "$trace_id" ]; then
        export HIVE_TRACE_ID="$trace_id"
    fi
    export HIVE_RUN_ID="$run_id"
}

# Read the entire scratchpad
scratchpad_read() {
    if [ -f "$SCRATCHPAD_FILE" ]; then
        cat "$SCRATCHPAD_FILE"
    else
        echo "{}"
    fi
}

# Get a specific field from scratchpad
scratchpad_get() {
    local field="$1"
    scratchpad_read | jq -r ".$field // empty"
}

# Update the scratchpad with a jq expression
scratchpad_update() {
    local jq_expr="$1"
    local current=$(scratchpad_read)
    local updated=$(echo "$current" | jq "$jq_expr" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.updated_at = $ts')
    echo "$updated" > "$SCRATCHPAD_FILE"
}

# ============================================================================
# Status Updates
# ============================================================================

# Generic setter for any field
scratchpad_set() {
    local key="$1"
    local value="$2"
    local current=$(scratchpad_read)
    local updated=$(echo "$current" | jq --arg v "$value" ".$key = \$v" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.updated_at = $ts')
    echo "$updated" > "$SCRATCHPAD_FILE"
}

scratchpad_set_status() {
    local status="$1"
    scratchpad_update ".status = \"$status\""
}

scratchpad_set_phase() {
    local phase="$1"
    scratchpad_update ".current_phase = \"$phase\""
}

scratchpad_set_agent() {
    local agent="$1"
    scratchpad_update ".current_agent = \"$agent\""
}

scratchpad_clear_agent() {
    scratchpad_update ".current_agent = null"
}

# ============================================================================
# Decisions
# ============================================================================

scratchpad_add_decision() {
    local agent="$1"
    local decision="$2"
    local rationale="${3:-}"
    
    local current=$(scratchpad_read)
    local new_decision=$(jq -n \
        --arg agent "$agent" \
        --arg decision "$decision" \
        --arg rationale "$rationale" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{ts: $ts, agent: $agent, decision: $decision, rationale: $rationale}'
    )
    echo "$current" | jq --argjson d "$new_decision" '.decisions += [$d]' > "$SCRATCHPAD_FILE"
}

# ============================================================================
# Blockers
# ============================================================================

scratchpad_add_blocker() {
    local agent="$1"
    local blocker="$2"
    local task_id="${3:-}"
    
    local current=$(scratchpad_read)
    local new_blocker=$(jq -n \
        --arg agent "$agent" \
        --arg blocker "$blocker" \
        --arg task_id "$task_id" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{ts: $ts, agent: $agent, blocker: $blocker, task_id: $task_id, status: "open", resolution: null}'
    )
    echo "$current" | jq --argjson b "$new_blocker" '.blockers += [$b]' > "$SCRATCHPAD_FILE"
}

scratchpad_resolve_blocker() {
    local index="$1"
    local resolution="$2"
    
    scratchpad_update ".blockers[$index].status = \"resolved\" | .blockers[$index].resolution = \"$resolution\""
}

# ============================================================================
# Context
# ============================================================================

scratchpad_add_tech() {
    local tech="$1"
    local current=$(scratchpad_read)
    echo "$current" | jq --arg t "$tech" '.context.tech_stack += [$t] | .context.tech_stack |= unique' > "$SCRATCHPAD_FILE"
}

scratchpad_add_key_file() {
    local file="$1"
    local current=$(scratchpad_read)
    echo "$current" | jq --arg f "$file" '.context.key_files += [$f] | .context.key_files |= unique' > "$SCRATCHPAD_FILE"
}

scratchpad_add_pattern() {
    local pattern="$1"
    local current=$(scratchpad_read)
    echo "$current" | jq --arg p "$pattern" '.context.patterns_established += [$p]' > "$SCRATCHPAD_FILE"
}

scratchpad_set_context() {
    local key="$1"
    local value="$2"
    scratchpad_update ".context.$key = \"$value\""
}

# ============================================================================
# Iteration Tracking
# ============================================================================

scratchpad_start_iteration() {
    local phase="$1"
    scratchpad_update ".iteration.phase = \"$phase\" | .iteration.attempt = 1"
}

scratchpad_increment_attempt() {
    scratchpad_update ".iteration.attempt += 1"
}

scratchpad_get_attempt() {
    scratchpad_get "iteration.attempt"
}

scratchpad_get_max_attempts() {
    scratchpad_get "iteration.max_attempts"
}

scratchpad_add_iteration_history() {
    local agent="$1"
    local result="$2"
    local error="${3:-}"
    
    local current=$(scratchpad_read)
    local entry=$(jq -n \
        --arg agent "$agent" \
        --arg result "$result" \
        --arg error "$error" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{ts: $ts, agent: $agent, result: $result} + (if $error != "" then {error: $error} else {} end)'
    )
    echo "$current" | jq --argjson e "$entry" '.iteration.history += [$e]' > "$SCRATCHPAD_FILE"
}

scratchpad_reset_iteration() {
    scratchpad_update ".iteration.phase = null | .iteration.attempt = 0 | .iteration.history = []"
}

# ============================================================================
# Agent Tracking
# ============================================================================

scratchpad_mark_agent_complete() {
    local agent="$1"
    local current=$(scratchpad_read)
    local entry=$(jq -n \
        --arg agent "$agent" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{agent: $agent, completed_at: $ts}'
    )
    echo "$current" | jq --argjson e "$entry" '.completed_agents += [$e]' > "$SCRATCHPAD_FILE"
}

scratchpad_is_agent_complete() {
    local agent="$1"
    local count=$(scratchpad_read | jq --arg a "$agent" '[.completed_agents[] | select(.agent == $a)] | length')
    [ "$count" -gt 0 ]
}

# ============================================================================
# Task Tracking
# ============================================================================

scratchpad_add_pending_task() {
    local task_id="$1"
    local title="$2"
    local assigned_agent="${3:-}"
    
    local current=$(scratchpad_read)
    local task=$(jq -n \
        --arg id "$task_id" \
        --arg title "$title" \
        --arg agent "$assigned_agent" \
        '{task_id: $id, title: $title, assigned_agent: $agent}'
    )
    echo "$current" | jq --argjson t "$task" '.pending_tasks += [$t]' > "$SCRATCHPAD_FILE"
}

scratchpad_complete_task() {
    local task_id="$1"
    
    local current=$(scratchpad_read)
    # Move from pending to completed
    local task=$(echo "$current" | jq --arg id "$task_id" '.pending_tasks[] | select(.task_id == $id)')
    
    if [ -n "$task" ]; then
        local completed_task=$(echo "$task" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '. + {completed_at: $ts}')
        echo "$current" | jq --arg id "$task_id" --argjson ct "$completed_task" \
            '.pending_tasks = [.pending_tasks[] | select(.task_id != $id)] | .completed_tasks += [$ct]' \
            > "$SCRATCHPAD_FILE"
    fi
}

# ============================================================================
# Summary for Agents
# ============================================================================

# Get a summary suitable for including in agent prompts
scratchpad_summary() {
    local sp=$(scratchpad_read)

    echo "$sp" | jq '{
        objective: .objective,
        status: .status,
        current_phase: .current_phase,
        decisions: [.decisions[-5:][] | {decision: .decision, rationale: .rationale}],
        open_blockers: [.blockers[] | select(.status == "open") | .blocker],
        context: .context,
        pending_tasks: [.pending_tasks[].title],
        completed_tasks: (.completed_tasks | length)
    }'
}

# ============================================================================
# Trace Context
# ============================================================================

# Set the trace ID for this run
scratchpad_set_trace_id() {
    local trace_id="$1"
    scratchpad_update ".trace_id = \"$trace_id\""
    export HIVE_TRACE_ID="$trace_id"
}

# Get the current trace ID
scratchpad_get_trace_id() {
    scratchpad_get "trace_id"
}

# Set the current span ID
scratchpad_set_span_id() {
    local span_id="$1"
    scratchpad_update ".current_span_id = \"$span_id\""
    export HIVE_CURRENT_SPAN_ID="$span_id"
}

# Get the current span ID
scratchpad_get_span_id() {
    scratchpad_get "current_span_id"
}

# Clear the current span ID
scratchpad_clear_span_id() {
    scratchpad_update ".current_span_id = null"
    unset HIVE_CURRENT_SPAN_ID
}

# Get full trace context as JSON
scratchpad_trace_context() {
    local sp=$(scratchpad_read)
    echo "$sp" | jq '{
        run_id: .run_id,
        trace_id: .trace_id,
        current_span_id: .current_span_id
    }'
}

# ============================================================================
# Nested Workflows (for composition feature)
# ============================================================================

# Add a nested workflow entry
scratchpad_add_nested_workflow() {
    local workflow_name="$1"
    local parent_scope="$2"

    local current=$(scratchpad_read)
    local entry=$(jq -n \
        --arg name "$workflow_name" \
        --arg scope "$parent_scope" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            name: $name,
            parent_scope: $scope,
            status: "in_progress",
            created_at: $ts,
            completed_at: null,
            scratchpad: null
        }'
    )
    echo "$current" | jq --argjson e "$entry" '.nested_workflows += [$e]' > "$SCRATCHPAD_FILE"
}

# Update nested workflow status
scratchpad_update_nested_workflow() {
    local workflow_name="$1"
    local status="$2"

    local current=$(scratchpad_read)
    local ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    if [ "$status" = "complete" ] || [ "$status" = "failed" ]; then
        echo "$current" | jq --arg name "$workflow_name" --arg status "$status" --arg ts "$ts" \
            '(.nested_workflows[] | select(.name == $name)) |= (. + {status: $status, completed_at: $ts})' \
            > "$SCRATCHPAD_FILE"
    else
        echo "$current" | jq --arg name "$workflow_name" --arg status "$status" \
            '(.nested_workflows[] | select(.name == $name)).status = $status' \
            > "$SCRATCHPAD_FILE"
    fi
}

# Get nested workflows summary
scratchpad_get_nested_workflows() {
    scratchpad_read | jq '.nested_workflows // []'
}
