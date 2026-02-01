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
