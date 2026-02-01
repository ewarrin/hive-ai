#!/usr/bin/env bash
# Hive Workflow Composition - Nested workflow execution
#
# Allows workflows to call other workflows as sub-pipelines.
# Provides context inheritance, nested checkpoints, and error bubbling.

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"

# ============================================================================
# Composition State
# ============================================================================

# Track nesting depth
_WORKFLOW_NESTING_DEPTH=0
_WORKFLOW_PARENT_RUN_ID=""
_WORKFLOW_PARENT_WORKFLOW=""

# ============================================================================
# Core Composition Functions
# ============================================================================

# Initialize composition context for a parent workflow
# Usage: workflow_compose_init <run_id> <workflow_name>
workflow_compose_init() {
    local run_id="$1"
    local workflow_name="$2"

    _WORKFLOW_PARENT_RUN_ID="$run_id"
    _WORKFLOW_PARENT_WORKFLOW="$workflow_name"
    _WORKFLOW_NESTING_DEPTH=0

    # Create composition tracking directory
    local compose_dir="$HIVE_DIR/runs/$run_id/.compose"
    mkdir -p "$compose_dir"

    # Initialize composition state
    jq -n \
        --arg run_id "$run_id" \
        --arg workflow "$workflow_name" \
        '{
            run_id: $run_id,
            parent_workflow: $workflow,
            nested_workflows: [],
            max_depth: 5,
            current_depth: 0
        }' > "$compose_dir/state.json"
}

# Execute a workflow as a sub-workflow
# Usage: workflow_execute_as_subworkflow <workflow_name> <run_id> <parent_phase>
workflow_execute_as_subworkflow() {
    local workflow_name="$1"
    local run_id="$2"
    local parent_phase="${3:-}"

    local compose_dir="$HIVE_DIR/runs/$run_id/.compose"

    # Check for circular references
    if ! workflow_validate_circular "$workflow_name" "$run_id"; then
        echo "Error: Circular workflow reference detected for $workflow_name" >&2
        return 1
    fi

    # Check nesting depth
    local current_depth=$(jq -r '.current_depth // 0' "$compose_dir/state.json" 2>/dev/null || echo "0")
    local max_depth=$(jq -r '.max_depth // 5' "$compose_dir/state.json" 2>/dev/null || echo "5")

    if [ "$current_depth" -ge "$max_depth" ]; then
        echo "Error: Maximum workflow nesting depth ($max_depth) exceeded" >&2
        return 1
    fi

    # Increment depth
    _WORKFLOW_NESTING_DEPTH=$((current_depth + 1))
    local state=$(cat "$compose_dir/state.json")
    echo "$state" | jq ".current_depth = $_WORKFLOW_NESTING_DEPTH" > "$compose_dir/state.json"

    # Record this nested workflow
    local nested_entry=$(jq -n \
        --arg name "$workflow_name" \
        --arg parent_phase "$parent_phase" \
        --argjson depth "$_WORKFLOW_NESTING_DEPTH" \
        --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            name: $name,
            parent_phase: $parent_phase,
            depth: $depth,
            started_at: $started_at,
            status: "running",
            completed_at: null,
            result: null
        }'
    )

    state=$(cat "$compose_dir/state.json")
    echo "$state" | jq --argjson entry "$nested_entry" '.nested_workflows += [$entry]' > "$compose_dir/state.json"

    # Add to scratchpad tracking
    if type scratchpad_add_nested_workflow &>/dev/null; then
        scratchpad_add_nested_workflow "$workflow_name" "$parent_phase"
    fi

    # Get workflow definition
    local workflow_def=$(workflow_get "$workflow_name" 2>/dev/null)

    if [ -z "$workflow_def" ] || [ "$workflow_def" == "null" ]; then
        echo "Error: Workflow '$workflow_name' not found" >&2
        workflow_mark_nested_complete "$workflow_name" "$run_id" "failed" "Workflow not found"
        return 1
    fi

    echo "$workflow_def"
    return 0
}

# Mark a nested workflow as complete
# Usage: workflow_mark_nested_complete <workflow_name> <run_id> <status> [result]
workflow_mark_nested_complete() {
    local workflow_name="$1"
    local run_id="$2"
    local status="$3"
    local result="${4:-}"

    local compose_dir="$HIVE_DIR/runs/$run_id/.compose"

    if [ ! -f "$compose_dir/state.json" ]; then
        return 1
    fi

    local state=$(cat "$compose_dir/state.json")
    local completed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Update the nested workflow entry
    echo "$state" | jq \
        --arg name "$workflow_name" \
        --arg status "$status" \
        --arg completed_at "$completed_at" \
        --arg result "$result" \
        '(.nested_workflows[] | select(.name == $name and .status == "running")) |= (
            . + {status: $status, completed_at: $completed_at, result: $result}
        )' > "$compose_dir/state.json"

    # Decrement depth
    state=$(cat "$compose_dir/state.json")
    local current_depth=$(echo "$state" | jq -r '.current_depth // 1')
    echo "$state" | jq ".current_depth = $(($current_depth - 1))" > "$compose_dir/state.json"

    _WORKFLOW_NESTING_DEPTH=$(($current_depth - 1))

    # Update scratchpad
    if type scratchpad_update_nested_workflow &>/dev/null; then
        scratchpad_update_nested_workflow "$workflow_name" "$status"
    fi
}

# ============================================================================
# Context Inheritance
# ============================================================================

# Inherit context from parent scratchpad to child
# Usage: workflow_context_inherit <parent_scratchpad>
workflow_context_inherit() {
    local parent_scratchpad="$1"

    if [ -z "$parent_scratchpad" ]; then
        echo "{}"
        return 0
    fi

    # Extract relevant context to pass to child
    echo "$parent_scratchpad" | jq '{
        objective: .objective,
        run_id: .run_id,
        trace_id: .trace_id,
        epic_id: .epic_id,
        context: .context,
        decisions: .decisions,
        parent_phase: .current_phase
    }'
}

# Merge child workflow results back into parent context
# Usage: workflow_context_merge <parent_scratchpad_file> <child_results>
workflow_context_merge() {
    local parent_file="$1"
    local child_results="$2"

    if [ ! -f "$parent_file" ]; then
        return 1
    fi

    local parent=$(cat "$parent_file")

    # Merge child decisions into parent
    local child_decisions=$(echo "$child_results" | jq '.decisions // []')
    if [ "$child_decisions" != "[]" ]; then
        parent=$(echo "$parent" | jq --argjson cd "$child_decisions" '.decisions += $cd')
    fi

    # Merge child completed tasks
    local child_tasks=$(echo "$child_results" | jq '.completed_tasks // []')
    if [ "$child_tasks" != "[]" ]; then
        parent=$(echo "$parent" | jq --argjson ct "$child_tasks" '.completed_tasks += $ct')
    fi

    # Merge child files modified into context
    local child_files=$(echo "$child_results" | jq '.context.key_files // []')
    if [ "$child_files" != "[]" ]; then
        parent=$(echo "$parent" | jq --argjson cf "$child_files" '.context.key_files += $cf | .context.key_files |= unique')
    fi

    # Update timestamp
    parent=$(echo "$parent" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.updated_at = $ts')

    echo "$parent" > "$parent_file"
}

# ============================================================================
# Circular Reference Detection
# ============================================================================

# Check for circular workflow references
# Usage: workflow_validate_circular <workflow_name> <run_id>
workflow_validate_circular() {
    local workflow_name="$1"
    local run_id="$2"

    local compose_dir="$HIVE_DIR/runs/$run_id/.compose"

    if [ ! -f "$compose_dir/state.json" ]; then
        # No composition state = no circular risk
        return 0
    fi

    # Check if this workflow is already in the call stack
    local in_stack=$(jq -r \
        --arg name "$workflow_name" \
        '[.nested_workflows[] | select(.name == $name and .status == "running")] | length' \
        "$compose_dir/state.json"
    )

    if [ "$in_stack" -gt 0 ]; then
        # Workflow is already running = circular reference
        return 1
    fi

    return 0
}

# ============================================================================
# Workflow Retrieval (wrapper for workflow.sh)
# ============================================================================

# Get workflow definition by name
# Checks local, global, and built-in workflows
workflow_get() {
    local name="$1"

    # Check local custom workflows
    local custom_path="$HIVE_DIR/workflows/${name}.json"
    if [ -f "$custom_path" ]; then
        cat "$custom_path"
        return 0
    fi

    # Check global custom workflows
    local global_path="$HIVE_ROOT/workflows/${name}.json"
    if [ -f "$global_path" ]; then
        cat "$global_path"
        return 0
    fi

    # Return null for built-in workflows (handled by workflow.sh)
    echo "null"
    return 1
}

# ============================================================================
# Composition Utilities
# ============================================================================

# Get current nesting depth
workflow_get_depth() {
    echo "$_WORKFLOW_NESTING_DEPTH"
}

# Check if we're in a nested workflow
workflow_is_nested() {
    [ "$_WORKFLOW_NESTING_DEPTH" -gt 0 ]
}

# Get parent workflow info
workflow_get_parent() {
    local run_id="$1"
    local compose_dir="$HIVE_DIR/runs/$run_id/.compose"

    if [ -f "$compose_dir/state.json" ]; then
        jq '{parent_workflow: .parent_workflow, run_id: .run_id}' "$compose_dir/state.json"
    else
        echo '{"parent_workflow": null, "run_id": null}'
    fi
}

# Get all nested workflows for a run
workflow_get_nested_all() {
    local run_id="$1"
    local compose_dir="$HIVE_DIR/runs/$run_id/.compose"

    if [ -f "$compose_dir/state.json" ]; then
        jq '.nested_workflows // []' "$compose_dir/state.json"
    else
        echo "[]"
    fi
}

# Get composition summary
workflow_composition_summary() {
    local run_id="$1"
    local compose_dir="$HIVE_DIR/runs/$run_id/.compose"

    if [ ! -f "$compose_dir/state.json" ]; then
        echo '{"has_composition": false}'
        return 0
    fi

    local state=$(cat "$compose_dir/state.json")

    echo "$state" | jq '{
        has_composition: true,
        parent_workflow: .parent_workflow,
        nested_count: (.nested_workflows | length),
        completed_count: ([.nested_workflows[] | select(.status == "complete" or .status == "failed")] | length),
        running_count: ([.nested_workflows[] | select(.status == "running")] | length),
        max_depth_reached: .current_depth,
        nested_workflows: [.nested_workflows[] | {name: .name, status: .status, depth: .depth}]
    }'
}

# ============================================================================
# Error Handling
# ============================================================================

# Handle nested workflow failure
# Usage: workflow_handle_nested_failure <workflow_name> <run_id> <error> <is_required>
workflow_handle_nested_failure() {
    local workflow_name="$1"
    local run_id="$2"
    local error="$3"
    local is_required="${4:-true}"

    # Mark as failed
    workflow_mark_nested_complete "$workflow_name" "$run_id" "failed" "$error"

    # Log the failure
    if type log_event &>/dev/null; then
        log_event "nested_workflow_failed" "$(jq -cn \
            --arg workflow "$workflow_name" \
            --arg error "$error" \
            --argjson required "$is_required" \
            '{workflow: $workflow, error: $error, required: $required}'
        )"
    fi

    # If required, return failure to bubble up
    if [ "$is_required" == "true" ]; then
        return 1
    fi

    # If optional, continue
    return 0
}
