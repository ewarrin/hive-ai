#!/usr/bin/env bash
# Hive Parallel Branches - Split work across multiple parallel branches
#
# Extends existing parallel execution to support workflow-level branching.
# Each branch runs its own sub-phases, then Comb agent merges results.

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"

# Maximum parallel branches (respect system limits)
MAX_PARALLEL_BRANCHES="${HIVE_MAX_PARALLEL:-3}"

# ============================================================================
# Branch State Management (Bash 3.x compatible - file-based)
# ============================================================================

# Initialize parallel branches state
# Usage: parallel_branches_init <run_id> <branches_json>
parallel_branches_init() {
    local run_id="$1"
    local branches_json="$2"

    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"
    mkdir -p "$branch_dir"

    # Store branches configuration
    echo "$branches_json" > "$branch_dir/branches.json"

    # Initialize state for each branch
    echo "$branches_json" | jq -c '.[]' | while read -r branch; do
        local branch_name=$(echo "$branch" | jq -r '.name')

        # Create branch state file
        jq -n \
            --arg name "$branch_name" \
            --arg status "pending" \
            --argjson branch "$branch" \
            '{
                name: $name,
                status: $status,
                branch: $branch,
                started_at: null,
                completed_at: null,
                pid: null,
                output_file: null,
                result: null,
                phases_completed: [],
                current_phase: null
            }' > "$branch_dir/${branch_name}.state.json"
    done

    # Initialize summary
    local branch_count=$(echo "$branches_json" | jq 'length')
    jq -n \
        --argjson count "$branch_count" \
        '{
            total_branches: $count,
            completed: 0,
            failed: 0,
            running: 0,
            pending: $count,
            merge_status: "pending"
        }' > "$branch_dir/summary.json"
}

# Get branch state
# Usage: parallel_branches_get_state <run_id> <branch_name>
parallel_branches_get_state() {
    local run_id="$1"
    local branch_name="$2"

    local state_file="$HIVE_DIR/runs/$run_id/.parallel_branches/${branch_name}.state.json"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo "{}"
    fi
}

# Update branch state
# Usage: parallel_branches_update_state <run_id> <branch_name> <jq_expression>
parallel_branches_update_state() {
    local run_id="$1"
    local branch_name="$2"
    local jq_expr="$3"

    local state_file="$HIVE_DIR/runs/$run_id/.parallel_branches/${branch_name}.state.json"
    if [ -f "$state_file" ]; then
        local state=$(cat "$state_file")
        echo "$state" | jq "$jq_expr" > "$state_file"
    fi
}

# Update summary
# Usage: parallel_branches_update_summary <run_id>
parallel_branches_update_summary() {
    local run_id="$1"
    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"

    local completed=0
    local failed=0
    local running=0
    local pending=0

    for state_file in "$branch_dir"/*.state.json; do
        [ -f "$state_file" ] || continue
        local status=$(jq -r '.status // "pending"' "$state_file")
        case "$status" in
            complete) completed=$((completed + 1)) ;;
            failed) failed=$((failed + 1)) ;;
            running) running=$((running + 1)) ;;
            pending) pending=$((pending + 1)) ;;
        esac
    done

    jq -n \
        --argjson completed "$completed" \
        --argjson failed "$failed" \
        --argjson running "$running" \
        --argjson pending "$pending" \
        '{
            total_branches: ($completed + $failed + $running + $pending),
            completed: $completed,
            failed: $failed,
            running: $running,
            pending: $pending,
            merge_status: (if $pending == 0 and $running == 0 then "ready" else "pending" end)
        }' > "$branch_dir/summary.json"
}

# ============================================================================
# Branch Execution
# ============================================================================

# Start a single branch in background
# Usage: parallel_branches_start_branch <run_id> <branch_name> <scratchpad_context>
parallel_branches_start_branch() {
    local run_id="$1"
    local branch_name="$2"
    local scratchpad_context="$3"

    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"
    local state_file="$branch_dir/${branch_name}.state.json"
    local output_file="$branch_dir/${branch_name}.output.txt"

    # Get branch definition
    local branch_def=$(jq -r ".branch" "$state_file")
    local phases=$(echo "$branch_def" | jq -c '.phases // []')

    # Update state to running
    parallel_branches_update_state "$run_id" "$branch_name" \
        ".status = \"running\" | .started_at = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\" | .output_file = \"$output_file\""

    # Execute branch phases in background
    (
        local branch_result="complete"
        local phases_completed="[]"

        echo "$phases" | jq -c '.[]' | while read -r phase; do
            local phase_name=$(echo "$phase" | jq -r '.name // "unnamed"')
            local agent=$(echo "$phase" | jq -r '.agent // "implementer"')
            local task=$(echo "$phase" | jq -r '.task // ""')

            echo "=== Branch $branch_name: Phase $phase_name (agent: $agent) ===" >> "$output_file"

            # Update current phase
            parallel_branches_update_state "$run_id" "$branch_name" \
                ".current_phase = \"$phase_name\""

            # TODO: Actually run the agent here
            # For now, mark phase as complete
            echo "Phase $phase_name completed" >> "$output_file"

            phases_completed=$(echo "$phases_completed" | jq --arg p "$phase_name" '. += [$p]')
            parallel_branches_update_state "$run_id" "$branch_name" \
                ".phases_completed = $phases_completed"
        done

        # Mark branch complete
        parallel_branches_update_state "$run_id" "$branch_name" \
            ".status = \"complete\" | .completed_at = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\" | .result = \"success\""

        parallel_branches_update_summary "$run_id"

    ) &

    local pid=$!
    parallel_branches_update_state "$run_id" "$branch_name" ".pid = $pid"
    parallel_branches_update_summary "$run_id"

    echo "$pid"
}

# Execute all branches in parallel
# Usage: parallel_branches_execute <run_id> [max_parallel]
parallel_branches_execute() {
    local run_id="$1"
    local max_parallel="${2:-$MAX_PARALLEL_BRANCHES}"

    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"
    local branches=$(cat "$branch_dir/branches.json")

    # Get current scratchpad for context
    local scratchpad=""
    if [ -f "$HIVE_DIR/scratchpad.json" ]; then
        scratchpad=$(cat "$HIVE_DIR/scratchpad.json")
    fi

    local running_count=0
    local pids=""

    # Start branches up to max_parallel limit
    echo "$branches" | jq -c '.[]' | while read -r branch; do
        local branch_name=$(echo "$branch" | jq -r '.name')

        # Check if we've hit the limit
        if [ "$running_count" -ge "$max_parallel" ]; then
            # Wait for any branch to complete
            wait -n 2>/dev/null || true
            running_count=$((running_count - 1))
        fi

        # Start the branch
        local pid=$(parallel_branches_start_branch "$run_id" "$branch_name" "$scratchpad")
        pids="$pids $pid"
        running_count=$((running_count + 1))

        echo "Started branch $branch_name (PID: $pid)"
    done

    # Return the list of PIDs
    echo "$pids"
}

# Wait for all branches to complete
# Usage: parallel_branches_wait <run_id> [timeout_seconds]
parallel_branches_wait() {
    local run_id="$1"
    local timeout="${2:-3600}"  # Default 1 hour timeout

    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"
    local start_time=$(date +%s)

    while true; do
        parallel_branches_update_summary "$run_id"
        local summary=$(cat "$branch_dir/summary.json")

        local running=$(echo "$summary" | jq -r '.running')
        local pending=$(echo "$summary" | jq -r '.pending')

        if [ "$running" -eq 0 ] && [ "$pending" -eq 0 ]; then
            echo "All branches complete"
            return 0
        fi

        # Check timeout
        local elapsed=$(($(date +%s) - start_time))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "Timeout waiting for branches"
            return 1
        fi

        sleep 2
    done
}

# ============================================================================
# Results Collection
# ============================================================================

# Collect results from all branches
# Usage: parallel_branches_collect_results <run_id>
parallel_branches_collect_results() {
    local run_id="$1"
    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"

    local results="[]"

    for state_file in "$branch_dir"/*.state.json; do
        [ -f "$state_file" ] || continue

        local state=$(cat "$state_file")
        local branch_name=$(echo "$state" | jq -r '.name')
        local status=$(echo "$state" | jq -r '.status')
        local output_file=$(echo "$state" | jq -r '.output_file // ""')

        local output=""
        if [ -f "$output_file" ]; then
            output=$(cat "$output_file")
        fi

        local result=$(jq -n \
            --arg name "$branch_name" \
            --arg status "$status" \
            --arg output "$output" \
            --argjson state "$state" \
            '{
                name: $name,
                status: $status,
                state: $state,
                output: $output
            }'
        )

        results=$(echo "$results" | jq --argjson r "$result" '. += [$r]')
    done

    echo "$results"
}

# ============================================================================
# Comb Integration (Merge)
# ============================================================================

# Prepare context for Comb agent to merge branches
# Usage: parallel_branches_prepare_merge_context <run_id>
parallel_branches_prepare_merge_context() {
    local run_id="$1"
    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"

    local summary=$(cat "$branch_dir/summary.json")
    local results=$(parallel_branches_collect_results "$run_id")

    # Build merge context
    jq -n \
        --argjson summary "$summary" \
        --argjson results "$results" \
        '{
            merge_type: "parallel_branches",
            summary: $summary,
            branches: $results,
            instructions: "Merge the work from all branches. Resolve any conflicts between branches. Ensure the combined result is coherent and functional."
        }'
}

# Invoke Comb agent to merge branches
# Usage: parallel_branches_invoke_comb <run_id>
parallel_branches_invoke_comb() {
    local run_id="$1"
    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"

    # Update merge status
    local summary=$(cat "$branch_dir/summary.json")
    echo "$summary" | jq '.merge_status = "in_progress"' > "$branch_dir/summary.json"

    # Prepare merge context
    local merge_context=$(parallel_branches_prepare_merge_context "$run_id")

    # Store context for Comb agent
    echo "$merge_context" > "$branch_dir/merge_context.json"

    # Log the merge start
    if type log_event &>/dev/null; then
        log_event "parallel_branches_merge_start" "$(jq -cn \
            --arg run_id "$run_id" \
            --argjson summary "$summary" \
            '{run_id: $run_id, summary: $summary}'
        )"
    fi

    # Return the path to merge context
    echo "$branch_dir/merge_context.json"
}

# Mark merge as complete
# Usage: parallel_branches_mark_merged <run_id> <status> [result]
parallel_branches_mark_merged() {
    local run_id="$1"
    local status="$2"
    local result="${3:-}"

    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"
    local summary=$(cat "$branch_dir/summary.json")

    echo "$summary" | jq \
        --arg status "$status" \
        --arg result "$result" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '.merge_status = $status | .merge_completed_at = $ts | .merge_result = $result' \
        > "$branch_dir/summary.json"

    # Log the merge completion
    if type log_event &>/dev/null; then
        log_event "parallel_branches_merge_complete" "$(jq -cn \
            --arg run_id "$run_id" \
            --arg status "$status" \
            '{run_id: $run_id, status: $status}'
        )"
    fi
}

# ============================================================================
# Utilities
# ============================================================================

# Get summary of parallel branches execution
# Usage: parallel_branches_summary <run_id>
parallel_branches_summary() {
    local run_id="$1"
    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"

    if [ ! -f "$branch_dir/summary.json" ]; then
        echo '{"status": "not_initialized"}'
        return 1
    fi

    cat "$branch_dir/summary.json"
}

# Check if all branches are complete
# Usage: parallel_branches_all_complete <run_id>
parallel_branches_all_complete() {
    local run_id="$1"
    local summary=$(parallel_branches_summary "$run_id")

    local running=$(echo "$summary" | jq -r '.running // 0')
    local pending=$(echo "$summary" | jq -r '.pending // 0')

    [ "$running" -eq 0 ] && [ "$pending" -eq 0 ]
}

# Check if any branch failed
# Usage: parallel_branches_has_failures <run_id>
parallel_branches_has_failures() {
    local run_id="$1"
    local summary=$(parallel_branches_summary "$run_id")

    local failed=$(echo "$summary" | jq -r '.failed // 0')
    [ "$failed" -gt 0 ]
}

# Print branch status (for TUI/logging)
# Usage: parallel_branches_print_status <run_id>
parallel_branches_print_status() {
    local run_id="$1"
    local branch_dir="$HIVE_DIR/runs/$run_id/.parallel_branches"

    echo ""
    echo "═══ Parallel Branches Status ═══"

    for state_file in "$branch_dir"/*.state.json; do
        [ -f "$state_file" ] || continue

        local state=$(cat "$state_file")
        local name=$(echo "$state" | jq -r '.name')
        local status=$(echo "$state" | jq -r '.status')
        local current_phase=$(echo "$state" | jq -r '.current_phase // "—"')

        local status_icon="○"
        case "$status" in
            complete) status_icon="✓" ;;
            failed) status_icon="✗" ;;
            running) status_icon="●" ;;
        esac

        printf "  %s %-20s %s\n" "$status_icon" "$name" "$current_phase"
    done

    echo ""
}
