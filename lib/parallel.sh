#!/usr/bin/env bash
# Hive Parallel Execution - Run multiple agents concurrently
#
# Note: Simplified for Bash 3.x compatibility (macOS default)
# Uses file-based state instead of associative arrays

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
MAX_PARALLEL="${HIVE_MAX_PARALLEL:-3}"

# Colors
_P_CYAN='\033[0;36m'
_P_GREEN='\033[0;32m'
_P_YELLOW='\033[1;33m'
_P_RED='\033[0;31m'
_P_DIM='\033[2m'
_P_BOLD='\033[1m'
_P_NC='\033[0m'

# ============================================================================
# File-based State (Bash 3 compatible)
# ============================================================================

_parallel_state_dir() {
    local run_id="${1:-current}"
    echo "$HIVE_DIR/runs/$run_id/.parallel"
}

_parallel_init_state() {
    local run_id="$1"
    local state_dir=$(_parallel_state_dir "$run_id")
    rm -rf "$state_dir"
    mkdir -p "$state_dir"
}

_parallel_set() {
    local run_id="$1"
    local agent="$2"
    local key="$3"
    local value="$4"
    local state_dir=$(_parallel_state_dir "$run_id")
    mkdir -p "$state_dir"
    echo "$value" > "$state_dir/${agent}.${key}"
}

_parallel_get() {
    local run_id="$1"
    local agent="$2"
    local key="$3"
    local state_dir=$(_parallel_state_dir "$run_id")
    local file="$state_dir/${agent}.${key}"
    [ -f "$file" ] && cat "$file"
}

_parallel_list_agents() {
    local run_id="$1"
    local state_dir=$(_parallel_state_dir "$run_id")
    [ -d "$state_dir" ] && ls "$state_dir"/*.pid 2>/dev/null | xargs -I{} basename {} .pid
}

# ============================================================================
# Core Functions
# ============================================================================

# Start an agent in background
parallel_start_agent() {
    local agent="$1"
    local task="$2"
    local handoff_id="$3"
    local run_id="$4"
    local epic_id="$5"
    
    local output_file="$HIVE_DIR/runs/$run_id/output/${agent}_parallel.txt"
    local status_file="$HIVE_DIR/runs/$run_id/output/${agent}_parallel.status"
    
    # Run agent in background subshell
    (
        # Source required libraries
        source "$(dirname "${BASH_SOURCE[0]}")/orchestrator.sh" 2>/dev/null || true
        
        local exit_code=0
        run_agent "$agent" "$task" "$handoff_id" > "$output_file" 2>&1
        exit_code=$?
        
        echo "$exit_code" > "$status_file"
    ) &
    
    local pid=$!
    
    # Store state in files
    _parallel_set "$run_id" "$agent" "pid" "$pid"
    _parallel_set "$run_id" "$agent" "output" "$output_file"
    _parallel_set "$run_id" "$agent" "status" "running"
    
    echo "$pid"
}

# Wait for all parallel agents to complete
parallel_wait_all() {
    local run_id="${1:-current}"
    local all_success=true
    
    local state_dir=$(_parallel_state_dir "$run_id")
    [ ! -d "$state_dir" ] && return 0
    
    for pid_file in "$state_dir"/*.pid; do
        [ -f "$pid_file" ] || continue
        
        local agent=$(basename "$pid_file" .pid)
        local pid=$(cat "$pid_file")
        
        wait $pid 2>/dev/null
        local exit_code=$?
        
        # Check status file for actual exit code
        local status_file="$HIVE_DIR/runs/$run_id/output/${agent}_parallel.status"
        if [ -f "$status_file" ]; then
            exit_code=$(cat "$status_file")
        fi
        
        if [ "$exit_code" -eq 0 ]; then
            _parallel_set "$run_id" "$agent" "status" "complete"
        else
            _parallel_set "$run_id" "$agent" "status" "failed"
            all_success=false
        fi
    done
    
    $all_success
}

# Check if any agents are still running
parallel_any_running() {
    local run_id="${1:-current}"
    local state_dir=$(_parallel_state_dir "$run_id")
    [ ! -d "$state_dir" ] && return 1
    
    for pid_file in "$state_dir"/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(cat "$pid_file")
        if kill -0 $pid 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Get status of a parallel agent
parallel_get_status() {
    local agent="$1"
    local run_id="${2:-current}"
    _parallel_get "$run_id" "$agent" "status"
}

# Get output file of a parallel agent
parallel_get_output() {
    local agent="$1"
    local run_id="${2:-current}"
    _parallel_get "$run_id" "$agent" "output"
}

# Reset parallel state
parallel_reset() {
    local run_id="${1:-current}"
    local state_dir=$(_parallel_state_dir "$run_id")
    rm -rf "$state_dir"
}

# ============================================================================
# Parallel Execution UI
# ============================================================================

parallel_display_progress() {
    local run_id="$1"
    local state_dir=$(_parallel_state_dir "$run_id")
    
    echo ""
    echo -e "${_P_CYAN}┌─────────────────────────────────────────────────────┐${_P_NC}"
    echo -e "${_P_CYAN}│${_P_NC}  ${_P_BOLD}⚡ Parallel Execution${_P_NC}                              ${_P_CYAN}│${_P_NC}"
    echo -e "${_P_CYAN}├─────────────────────────────────────────────────────┤${_P_NC}"
    
    [ ! -d "$state_dir" ] && return
    
    for pid_file in "$state_dir"/*.pid; do
        [ -f "$pid_file" ] || continue
        
        local agent=$(basename "$pid_file" .pid)
        local pid=$(cat "$pid_file")
        local status=$(_parallel_get "$run_id" "$agent" "status")
        
        local icon=""
        local color=""
        
        case "$status" in
            running)
                if kill -0 $pid 2>/dev/null; then
                    icon="⋯"
                    color="$_P_YELLOW"
                else
                    icon="✓"
                    color="$_P_GREEN"
                fi
                ;;
            complete)
                icon="✓"
                color="$_P_GREEN"
                ;;
            failed)
                icon="✗"
                color="$_P_RED"
                ;;
            *)
                icon="○"
                color="$_P_DIM"
                ;;
        esac
        
        printf "${_P_CYAN}│${_P_NC}  ${color}${icon}${_P_NC} %-20s ${_P_DIM}pid:%-6s${_P_NC}            ${_P_CYAN}│${_P_NC}\n" "$agent" "$pid"
    done
    
    echo -e "${_P_CYAN}└─────────────────────────────────────────────────────┘${_P_NC}"
}

# ============================================================================
# Parallel Workflow Helpers
# ============================================================================

# Run review phase agents in parallel
parallel_run_review_phase() {
    local run_id="$1"
    local epic_id="$2"
    local handoff_id="$3"
    local objective="$4"
    
    _parallel_init_state "$run_id"
    
    echo ""
    echo -e "${_P_BOLD}Starting parallel review phase...${_P_NC}"
    
    # Determine which review agents to run
    local agents_to_run="reviewer"
    
    # Add tester if tests exist
    if [ -d "tests" ] || [ -d "__tests__" ] || [ -d "test" ]; then
        agents_to_run="$agents_to_run tester"
    fi
    
    # Start agents in parallel
    local agent_count=0
    for agent in $agents_to_run; do
        echo -e "  ${_P_CYAN}▶${_P_NC} Starting ${_P_BOLD}$agent${_P_NC}..."
        parallel_start_agent "$agent" "Review the implementation for: $objective" "$handoff_id" "$run_id" "$epic_id"
        agent_count=$((agent_count + 1))
    done
    
    echo ""
    echo -e "${_P_DIM}$agent_count agents running in parallel${_P_NC}"
    echo ""
    
    # Wait for all to complete
    parallel_wait_all "$run_id"
    
    echo ""
    
    # Collect results
    local all_success=true
    
    for agent in $agents_to_run; do
        local status=$(parallel_get_status "$agent" "$run_id")
        local output=$(parallel_get_output "$agent" "$run_id")
        
        if [ "$status" = "complete" ]; then
            echo -e "  ${_P_GREEN}✓${_P_NC} $agent completed"
            
            # Copy output to standard location
            if [ -f "$output" ]; then
                cp "$output" "$HIVE_DIR/runs/$run_id/output/${agent}.txt"
            fi
        else
            echo -e "  ${_P_RED}✗${_P_NC} $agent failed"
            all_success=false
        fi
    done
    
    echo ""
    
    $all_success
}

# Check if parallel execution is enabled
parallel_is_enabled() {
    [ "${HIVE_PARALLEL:-1}" = "1" ]
}

# Merge findings from multiple parallel review agents
parallel_merge_findings() {
    local run_id="$1"
    local epic_id="$2"
    
    local merged_findings="[]"
    
    for agent in reviewer security e2e-tester tester; do
        local output="$HIVE_DIR/runs/$run_id/output/${agent}.txt"
        
        if [ -f "$output" ]; then
            local report=$(sed -n '/<!--HIVE_REPORT/,/HIVE_REPORT-->/p' "$output" | sed '1d;$d')
            
            if [ -n "$report" ] && echo "$report" | jq . >/dev/null 2>&1; then
                local issues=$(echo "$report" | jq -c --arg agent "$agent" '
                    (.issues // .issues_found // .findings // []) | 
                    map(. + {source_agent: $agent})
                ' 2>/dev/null)
                
                if [ -n "$issues" ] && [ "$issues" != "null" ] && [ "$issues" != "[]" ]; then
                    merged_findings=$(echo "$merged_findings" | jq --argjson new "$issues" '. + $new')
                fi
            fi
        fi
    done
    
    echo "$merged_findings"
}

# ============================================================================
# Git Worktree-Based Parallel Execution
# ============================================================================

WORKTREE_BASE_DIR="${HIVE_DIR}/worktrees"

# Check if git worktrees are supported and available
worktree_available() {
    if ! command -v git &>/dev/null; then
        return 1
    fi
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        return 1
    fi
    # Check if we're already in a worktree (nested worktrees not supported)
    if git rev-parse --is-inside-work-tree &>/dev/null && \
       [ "$(git rev-parse --git-common-dir)" != "$(git rev-parse --git-dir)" ]; then
        return 1
    fi
    return 0
}

# Create a worktree for a specific task
# Usage: worktree_create <task_id> <run_id>
# Returns: Path to worktree directory
worktree_create() {
    local task_id="$1"
    local run_id="$2"
    local base_branch="${3:-HEAD}"

    if ! worktree_available; then
        echo ""
        return 1
    fi

    local worktree_dir="$WORKTREE_BASE_DIR/$run_id/$task_id"
    local branch_name="hive/task/${run_id}/${task_id}"

    # Ensure base directory exists
    mkdir -p "$(dirname "$worktree_dir")"

    # Create worktree with new branch
    if git worktree add -b "$branch_name" "$worktree_dir" "$base_branch" 2>/dev/null; then
        echo "$worktree_dir"
        return 0
    else
        # Branch might already exist, try without -b
        if git worktree add "$worktree_dir" "$branch_name" 2>/dev/null; then
            echo "$worktree_dir"
            return 0
        fi
    fi

    echo ""
    return 1
}

# Run an agent inside an isolated worktree
# Usage: worktree_run_agent <worktree_dir> <agent> <task> <run_id> <epic_id>
worktree_run_agent() {
    local worktree_dir="$1"
    local agent="$2"
    local task="$3"
    local run_id="$4"
    local epic_id="$5"

    if [ ! -d "$worktree_dir" ]; then
        echo "Worktree not found: $worktree_dir" >&2
        return 1
    fi

    local task_id=$(basename "$worktree_dir")
    local output_file="$HIVE_DIR/runs/$run_id/output/${agent}_${task_id}.txt"
    local status_file="$HIVE_DIR/runs/$run_id/output/${agent}_${task_id}.status"

    # Run agent in worktree directory as background job
    (
        cd "$worktree_dir" || exit 1

        # Source orchestrator for run_agent function
        source "$(dirname "${BASH_SOURCE[0]}")/orchestrator.sh" 2>/dev/null || true

        # Override HIVE_DIR to use the main project's .hive
        # but work in the worktree
        local original_pwd=$(pwd)

        local exit_code=0
        run_agent "$agent" "$task" "" "$output_file" 2>&1
        exit_code=$?

        echo "$exit_code" > "$status_file"

        # If successful, commit the changes in the worktree
        if [ $exit_code -eq 0 ]; then
            git add -A 2>/dev/null || true
            git commit -m "[$agent] $task_id: $(echo "$task" | head -c 50)" 2>/dev/null || true
        fi
    ) &

    local pid=$!

    # Store worktree state
    _parallel_set "$run_id" "${agent}_${task_id}" "pid" "$pid"
    _parallel_set "$run_id" "${agent}_${task_id}" "worktree" "$worktree_dir"
    _parallel_set "$run_id" "${agent}_${task_id}" "status" "running"

    echo "$pid"
}

# Clean up a worktree after merge
# Usage: worktree_cleanup <task_id> <run_id> [delete_branch]
worktree_cleanup() {
    local task_id="$1"
    local run_id="$2"
    local delete_branch="${3:-true}"

    local worktree_dir="$WORKTREE_BASE_DIR/$run_id/$task_id"
    local branch_name="hive/task/${run_id}/${task_id}"

    # Remove worktree
    if [ -d "$worktree_dir" ]; then
        git worktree remove "$worktree_dir" --force 2>/dev/null || true
    fi

    # Delete branch if requested
    if [ "$delete_branch" = "true" ]; then
        git branch -D "$branch_name" 2>/dev/null || true
    fi

    # Clean up state files
    local state_dir=$(_parallel_state_dir "$run_id")
    rm -f "$state_dir"/*_${task_id}.* 2>/dev/null || true
}

# List all active worktrees for a run
# Usage: worktree_list <run_id>
worktree_list() {
    local run_id="$1"
    local worktree_run_dir="$WORKTREE_BASE_DIR/$run_id"

    if [ -d "$worktree_run_dir" ]; then
        for dir in "$worktree_run_dir"/*/; do
            [ -d "$dir" ] || continue
            local task_id=$(basename "$dir")
            local status=$(_parallel_get "$run_id" "implementer_${task_id}" "status" 2>/dev/null || echo "unknown")
            echo "$task_id|$dir|$status"
        done
    fi
}

# Wait for all worktree agents to complete
# Usage: worktree_wait_all <run_id>
worktree_wait_all() {
    local run_id="$1"
    local state_dir=$(_parallel_state_dir "$run_id")
    local all_success=true

    [ ! -d "$state_dir" ] && return 0

    for pid_file in "$state_dir"/*.pid; do
        [ -f "$pid_file" ] || continue

        local agent_task=$(basename "$pid_file" .pid)
        local pid=$(cat "$pid_file")

        # Wait for process
        wait $pid 2>/dev/null
        local exit_code=$?

        # Check status file for actual exit code
        local status_file="$HIVE_DIR/runs/$run_id/output/${agent_task}.status"
        if [ -f "$status_file" ]; then
            exit_code=$(cat "$status_file")
        fi

        if [ "$exit_code" -eq 0 ]; then
            _parallel_set "$run_id" "$agent_task" "status" "complete"
        else
            _parallel_set "$run_id" "$agent_task" "status" "failed"
            all_success=false
        fi
    done

    $all_success
}

# Get branches from all completed worktrees for merging
# Usage: worktree_get_merge_branches <run_id>
worktree_get_merge_branches() {
    local run_id="$1"
    local branches=""

    worktree_list "$run_id" | while IFS='|' read -r task_id dir status; do
        if [ "$status" = "complete" ]; then
            echo "hive/task/${run_id}/${task_id}"
        fi
    done
}

# Clean up all worktrees for a run
# Usage: worktree_cleanup_all <run_id>
worktree_cleanup_all() {
    local run_id="$1"

    worktree_list "$run_id" | while IFS='|' read -r task_id dir status; do
        worktree_cleanup "$task_id" "$run_id" "true"
    done

    # Remove the run's worktree directory
    rm -rf "$WORKTREE_BASE_DIR/$run_id" 2>/dev/null || true
}

# ============================================================================
# Parallel Worktree Execution
# ============================================================================

# Run multiple tasks in parallel worktrees
# Usage: worktree_run_parallel <run_id> <epic_id> <task_json_array>
worktree_run_parallel() {
    local run_id="$1"
    local epic_id="$2"
    local tasks_json="$3"

    if ! worktree_available; then
        echo -e "${_P_YELLOW}⚠${_P_NC} Git worktrees not available, falling back to sequential" >&2
        return 1
    fi

    _parallel_init_state "$run_id"

    local task_count=$(echo "$tasks_json" | jq 'length')

    echo ""
    echo -e "${_P_BOLD}Starting parallel execution in worktrees...${_P_NC}"
    echo -e "${_P_DIM}$task_count tasks to run${_P_NC}"
    echo ""

    # Create worktrees and start agents for each task
    local started=0
    echo "$tasks_json" | jq -c '.[]' | while IFS= read -r task_obj; do
        local task_id=$(echo "$task_obj" | jq -r '.id // .task_id // ("task_" + (now | tostring | split(".")[0]))')
        local task_title=$(echo "$task_obj" | jq -r '.title // .description // "Implement task"')

        # Limit concurrent worktrees
        while [ $(worktree_list "$run_id" | grep -c "running") -ge "$MAX_PARALLEL" ]; do
            sleep 2
        done

        echo -e "  ${_P_CYAN}▶${_P_NC} Creating worktree for ${_P_BOLD}$task_id${_P_NC}..."

        local worktree_dir=$(worktree_create "$task_id" "$run_id")
        if [ -z "$worktree_dir" ]; then
            echo -e "  ${_P_RED}✗${_P_NC} Failed to create worktree for $task_id"
            continue
        fi

        echo -e "  ${_P_CYAN}▶${_P_NC} Starting implementer in worktree..."
        worktree_run_agent "$worktree_dir" "implementer" "$task_title" "$run_id" "$epic_id"

        started=$((started + 1))
    done

    echo ""
    echo -e "${_P_DIM}$started worktree agents started${_P_NC}"

    # Wait for all to complete
    worktree_wait_all "$run_id"
    local result=$?

    echo ""

    # Show results
    worktree_list "$run_id" | while IFS='|' read -r task_id dir status; do
        local icon="${_P_GREEN}✓${_P_NC}"
        [ "$status" != "complete" ] && icon="${_P_RED}✗${_P_NC}"
        echo -e "  $icon $task_id: $status"
    done

    return $result
}

# Display parallel worktree progress
worktree_display_progress() {
    local run_id="$1"

    echo ""
    echo -e "${_P_CYAN}┌─────────────────────────────────────────────────────┐${_P_NC}"
    echo -e "${_P_CYAN}│${_P_NC}  ${_P_BOLD}⚡ Parallel Worktrees${_P_NC}                             ${_P_CYAN}│${_P_NC}"
    echo -e "${_P_CYAN}├─────────────────────────────────────────────────────┤${_P_NC}"

    worktree_list "$run_id" | while IFS='|' read -r task_id dir status; do
        local icon=""
        local color=""

        case "$status" in
            running)
                icon="⋯"
                color="$_P_YELLOW"
                ;;
            complete)
                icon="✓"
                color="$_P_GREEN"
                ;;
            failed)
                icon="✗"
                color="$_P_RED"
                ;;
            *)
                icon="○"
                color="$_P_DIM"
                ;;
        esac

        printf "${_P_CYAN}│${_P_NC}  ${color}${icon}${_P_NC} %-20s ${_P_DIM}%-20s${_P_NC}${_P_CYAN}│${_P_NC}\n" "$task_id" "$status"
    done

    echo -e "${_P_CYAN}└─────────────────────────────────────────────────────┘${_P_NC}"
}

# ============================================================================
# Task Dependency Analysis
# ============================================================================

# Analyze tasks from beads to determine parallelism
# Usage: analyze_task_parallelism <epic_id>
# Returns: JSON with parallel and sequential task arrays
analyze_task_parallelism() {
    local epic_id="$1"

    if ! command -v bd &>/dev/null; then
        echo '{"parallel": [], "sequential": [], "error": "beads not available"}'
        return 1
    fi

    # Get all tasks for this epic
    local all_tasks=$(bd list --json 2>/dev/null || echo "[]")

    # Filter to tasks under this epic
    local epic_tasks=$(echo "$all_tasks" | jq --arg epic "$epic_id" '
        [.[] | select(
            .id | startswith($epic) or
            .parent == $epic or
            (.parent | startswith($epic) // false)
        ) | select(.status != "closed")]
    ')

    # Separate into independent (no blockers) and dependent tasks
    local parallel_tasks=$(echo "$epic_tasks" | jq '
        [.[] | select(
            (.blocked_by == null or .blocked_by == [] or (.blocked_by | length) == 0) and
            (.status == "open" or .status == "ready")
        )]
    ')

    local sequential_tasks=$(echo "$epic_tasks" | jq '
        [.[] | select(
            .blocked_by != null and (.blocked_by | length) > 0
        )]
    ')

    # Build result
    jq -cn \
        --argjson parallel "$parallel_tasks" \
        --argjson sequential "$sequential_tasks" \
        '{parallel: $parallel, sequential: $sequential}'
}

# Get the next batch of tasks that can run in parallel
# Usage: get_parallel_batch <epic_id> [max_batch_size]
get_parallel_batch() {
    local epic_id="$1"
    local max_batch="${2:-$MAX_PARALLEL}"

    local analysis=$(analyze_task_parallelism "$epic_id")
    local parallel_tasks=$(echo "$analysis" | jq '.parallel')

    # Return up to max_batch tasks
    echo "$parallel_tasks" | jq --argjson max "$max_batch" '.[:$max]'
}

# Check if a task's dependencies are satisfied
# Usage: task_dependencies_satisfied <task_id>
task_dependencies_satisfied() {
    local task_id="$1"

    if ! command -v bd &>/dev/null; then
        return 0  # Assume satisfied if we can't check
    fi

    local task=$(bd get "$task_id" --json 2>/dev/null)
    if [ -z "$task" ]; then
        return 0
    fi

    local blocked_by=$(echo "$task" | jq -r '.blocked_by // []')
    if [ "$blocked_by" = "[]" ] || [ "$blocked_by" = "null" ]; then
        return 0
    fi

    # Check each blocker
    local all_closed=true
    echo "$blocked_by" | jq -r '.[]' 2>/dev/null | while read -r blocker_id; do
        [ -z "$blocker_id" ] && continue
        local blocker=$(bd get "$blocker_id" --json 2>/dev/null)
        local blocker_status=$(echo "$blocker" | jq -r '.status // "open"')
        if [ "$blocker_status" != "closed" ]; then
            echo "blocked"
            return
        fi
    done

    return 0
}

# Infer file dependencies from task descriptions
# Usage: infer_file_dependencies <task_json>
# Returns: List of files that task might touch
infer_file_dependencies() {
    local task_json="$1"

    local title=$(echo "$task_json" | jq -r '.title // ""')
    local description=$(echo "$task_json" | jq -r '.description // ""')

    local combined="$title $description"

    # Look for common path patterns
    echo "$combined" | grep -oE '[a-zA-Z0-9_/.-]+\.(ts|js|vue|tsx|jsx|py|go|rs|md)' | sort -u
}

# Check if two tasks might conflict based on file dependencies
# Usage: tasks_might_conflict <task1_json> <task2_json>
tasks_might_conflict() {
    local task1="$1"
    local task2="$2"

    local files1=$(infer_file_dependencies "$task1")
    local files2=$(infer_file_dependencies "$task2")

    # Check for overlap
    for f1 in $files1; do
        for f2 in $files2; do
            if [ "$f1" = "$f2" ]; then
                return 0  # Conflict possible
            fi
        done
    done

    return 1  # No conflict detected
}
