#!/usr/bin/env bash
# Hive Progress UI - Status bar and activity streaming
#
# Features:
# - Persistent status bar at bottom of terminal
# - Activity streaming with condensed output
# - Phase progress indicators

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"

# Colors
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_BLUE='\033[0;34m'
_CYAN='\033[0;36m'
_MAGENTA='\033[0;35m'
_BOLD='\033[1m'
_DIM='\033[2m'
_NC='\033[0m'

# Status bar state
_PROGRESS_AGENT=""
_PROGRESS_PHASE=""
_PROGRESS_START_TIME=""
_PROGRESS_TASKS_OPEN=0
_PROGRESS_TASKS_CLOSED=0
_PROGRESS_FILES_CHANGED=0
_PROGRESS_ENABLED=true

# Terminal control
_TERM_LINES=$(tput lines 2>/dev/null || echo 24)
_TERM_COLS=$(tput cols 2>/dev/null || echo 80)

# ============================================================================
# Status Bar
# ============================================================================

# Initialize progress tracking
progress_init() {
    _PROGRESS_START_TIME=$(date +%s)
    _PROGRESS_AGENT=""
    _PROGRESS_PHASE=""
    _PROGRESS_TASKS_OPEN=0
    _PROGRESS_TASKS_CLOSED=0
    _PROGRESS_FILES_CHANGED=0
    
    # Check if we're in a terminal
    if [ ! -t 1 ]; then
        _PROGRESS_ENABLED=false
    fi
}

# Update status bar values
progress_set_agent() {
    _PROGRESS_AGENT="$1"
}

progress_set_phase() {
    _PROGRESS_PHASE="$1"
}

progress_set_tasks() {
    _PROGRESS_TASKS_OPEN="${1:-0}"
    _PROGRESS_TASKS_CLOSED="${2:-0}"
}

progress_set_files() {
    _PROGRESS_FILES_CHANGED="${1:-0}"
}

progress_increment_files() {
    _PROGRESS_FILES_CHANGED=$((_PROGRESS_FILES_CHANGED + 1))
}

# Calculate elapsed time
_progress_elapsed() {
    local now=$(date +%s)
    local elapsed=$((now - _PROGRESS_START_TIME))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    printf "%d:%02d" "$mins" "$secs"
}

# Render the status bar (call periodically or on update)
progress_render_bar() {
    [ "$_PROGRESS_ENABLED" = false ] && return
    
    local elapsed=$(_progress_elapsed)
    local agent="${_PROGRESS_AGENT:-waiting}"
    local phase="${_PROGRESS_PHASE:-}"
    
    # Build status string
    local status=""
    
    # Agent indicator with spinner
    local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spinner_idx=$(( $(date +%s) % 10 ))
    local spinner="${spinner_chars:$spinner_idx:1}"
    
    if [ -n "$_PROGRESS_AGENT" ]; then
        status="${_CYAN}${spinner}${_NC} ${_BOLD}${agent}${_NC}"
    else
        status="${_DIM}waiting${_NC}"
    fi
    
    # Phase
    if [ -n "$phase" ]; then
        status="$status ${_DIM}│${_NC} ${phase}"
    fi
    
    # Time
    status="$status ${_DIM}│${_NC} ${_BLUE}⏱ ${elapsed}${_NC}"
    
    # Tasks
    if [ "$_PROGRESS_TASKS_OPEN" -gt 0 ] || [ "$_PROGRESS_TASKS_CLOSED" -gt 0 ]; then
        status="$status ${_DIM}│${_NC} ${_YELLOW}◯${_NC}${_PROGRESS_TASKS_OPEN} ${_GREEN}●${_NC}${_PROGRESS_TASKS_CLOSED}"
    fi
    
    # Files
    if [ "$_PROGRESS_FILES_CHANGED" -gt 0 ]; then
        status="$status ${_DIM}│${_NC} ${_MAGENTA}◇${_NC}${_PROGRESS_FILES_CHANGED} files"
    fi
    
    # Print on a single line, clearing to end
    echo -en "\r\033[K"
    echo -en "$status"
}

# Clear the status bar
progress_clear_bar() {
    [ "$_PROGRESS_ENABLED" = false ] && return
    echo -en "\r\033[K"
}

# Print a status bar as a static line (for checkpoints)
progress_print_summary() {
    local elapsed=$(_progress_elapsed)
    
    echo ""
    echo -e "${_DIM}────────────────────────────────────────${_NC}"
    echo -e "  ${_BLUE}⏱${_NC}  Elapsed: ${_BOLD}${elapsed}${_NC}"
    
    if [ "$_PROGRESS_TASKS_CLOSED" -gt 0 ] || [ "$_PROGRESS_TASKS_OPEN" -gt 0 ]; then
        echo -e "  ${_GREEN}●${_NC}  Tasks: ${_PROGRESS_TASKS_CLOSED} closed, ${_PROGRESS_TASKS_OPEN} open"
    fi
    
    if [ "$_PROGRESS_FILES_CHANGED" -gt 0 ]; then
        echo -e "  ${_MAGENTA}◇${_NC}  Files: ${_PROGRESS_FILES_CHANGED} changed"
    fi
    
    echo -e "${_DIM}────────────────────────────────────────${_NC}"
}

# ============================================================================
# Activity Streaming
# ============================================================================

# Filter and display agent activity in real-time
# Reads from stdin, outputs condensed activity
progress_stream_activity() {
    local agent="${1:-agent}"
    local current_file=""
    local files_seen=()
    local line_count=0
    local last_activity=""
    local activity_count=0
    
    # Patterns to detect and summarize
    while IFS= read -r line; do
        line_count=$((line_count + 1))
        
        # Always pass through the raw output (but we could filter in future)
        echo "$line"
        
        # Detect file operations
        if echo "$line" | grep -qE "^(Reading|Writing|Creating|Modifying|Checking) "; then
            local activity=$(echo "$line" | grep -oE "^(Reading|Writing|Creating|Modifying|Checking)")
            local file=$(echo "$line" | grep -oE "[^ ]+\.(ts|js|vue|tsx|jsx|py|rs|go|md|json|css|scss)(\s|$)" | head -1)
            
            if [ -n "$file" ] && [ "$file" != "$current_file" ]; then
                current_file="$file"
                _progress_activity "$activity" "$file"
            fi
        fi
        
        # Detect tool use (claude's tool calls)
        if echo "$line" | grep -qE "^\[tool\]|^Tool:|^Using tool:"; then
            local tool=$(echo "$line" | grep -oE "(read|write|edit|bash|search|grep)" | head -1)
            if [ -n "$tool" ]; then
                _progress_activity "Tool" "$tool"
            fi
        fi
        
        # Detect file reads (cat, view commands)
        if echo "$line" | grep -qE "^(cat|less|head|tail|view) [^ ]+"; then
            local file=$(echo "$line" | grep -oE "[^ ]+\.(ts|js|vue|tsx|jsx|py|rs|go|md|json)" | head -1)
            if [ -n "$file" ]; then
                _progress_activity "Reading" "$file"
                progress_increment_files
            fi
        fi
        
        # Detect file writes
        if echo "$line" | grep -qE "^(Writing to|Created|Modified|Updated) "; then
            local file=$(echo "$line" | grep -oE "[^ ]+\.(ts|js|vue|tsx|jsx|py|rs|go|md|json)" | head -1)
            if [ -n "$file" ]; then
                _progress_activity "Writing" "$file"
                progress_increment_files
            fi
        fi
        
        # Detect test runs
        if echo "$line" | grep -qE "(PASS|FAIL|✓|✗|passed|failed).*test"; then
            local result="tests"
            if echo "$line" | grep -qiE "pass|✓"; then
                _progress_activity "Passed" "tests"
            elif echo "$line" | grep -qiE "fail|✗"; then
                _progress_activity "Failed" "tests"
            fi
        fi
        
        # Detect Beads operations
        if echo "$line" | grep -qE "^bd (create|close|update|note)"; then
            local op=$(echo "$line" | grep -oE "(create|close|update|note)")
            local task_id=$(echo "$line" | grep -oE "bd-[a-z0-9]+" | head -1)
            if [ "$op" = "close" ]; then
                _PROGRESS_TASKS_CLOSED=$((_PROGRESS_TASKS_CLOSED + 1))
                _PROGRESS_TASKS_OPEN=$((_PROGRESS_TASKS_OPEN - 1))
                [ $_PROGRESS_TASKS_OPEN -lt 0 ] && _PROGRESS_TASKS_OPEN=0
            elif [ "$op" = "create" ]; then
                _PROGRESS_TASKS_OPEN=$((_PROGRESS_TASKS_OPEN + 1))
            fi
            _progress_activity "Beads" "$op ${task_id:-task}"
        fi
        
    done
}

# Print a condensed activity line
_progress_activity() {
    local action="$1"
    local target="$2"
    
    # Color by action type
    local color="$_DIM"
    case "$action" in
        Reading|Tool) color="$_BLUE" ;;
        Writing|Creating|Modifying) color="$_GREEN" ;;
        Passed) color="$_GREEN" ;;
        Failed) color="$_RED" ;;
        Beads) color="$_YELLOW" ;;
    esac
    
    # Truncate target if too long
    if [ ${#target} -gt 40 ]; then
        target="...${target: -37}"
    fi
    
    # Print inline activity indicator
    echo -e "  ${color}${action}${_NC} ${_DIM}${target}${_NC}" >&2
}

# ============================================================================
# Phase Progress Display
# ============================================================================

# Show workflow phases with current position
progress_show_phases() {
    local current_phase="$1"
    shift
    local phases=("$@")
    
    echo ""
    echo -e "${_BOLD}Workflow Progress${_NC}"
    echo -e "${_DIM}─────────────────${_NC}"
    
    local found_current=false
    for phase in "${phases[@]}"; do
        if [ "$phase" = "$current_phase" ]; then
            echo -e "  ${_CYAN}▶${_NC} ${_BOLD}${phase}${_NC} ${_CYAN}← current${_NC}"
            found_current=true
        elif [ "$found_current" = false ]; then
            echo -e "  ${_GREEN}✓${_NC} ${_DIM}${phase}${_NC}"
        else
            echo -e "  ${_DIM}○ ${phase}${_NC}"
        fi
    done
    echo ""
}

# Show a spinner while waiting
progress_spinner() {
    local pid=$1
    local message="${2:-Working}"
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    while kill -0 "$pid" 2>/dev/null; do
        local char="${spinner:$i:1}"
        echo -en "\r${_CYAN}${char}${_NC} ${message}..."
        i=$(( (i + 1) % 10 ))
        sleep 0.1
    done
    echo -en "\r\033[K"
}

# ============================================================================
# Checkpoint Display Enhancement
# ============================================================================

# Show enhanced checkpoint with summary
progress_checkpoint_display() {
    local agent="$1"
    local confidence="$2"
    local files_modified="$3"
    local issues_found="$4"
    local summary="$5"
    
    echo ""
    echo -e "${_BOLD}${_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_NC}"
    echo -e "${_BOLD}  ${agent} complete${_NC}"
    echo -e "${_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_NC}"
    echo ""
    
    # Confidence indicator
    local conf_color="$_GREEN"
    local conf_bar=""
    local conf_num=$(echo "$confidence" | awk '{printf "%.0f", $1 * 10}')
    
    if (( $(echo "$confidence < 0.7" | bc -l 2>/dev/null || echo 0) )); then
        conf_color="$_RED"
    elif (( $(echo "$confidence < 0.85" | bc -l 2>/dev/null || echo 0) )); then
        conf_color="$_YELLOW"
    fi
    
    # Build confidence bar
    for ((i=0; i<10; i++)); do
        if [ $i -lt ${conf_num:-8} ]; then
            conf_bar="${conf_bar}█"
        else
            conf_bar="${conf_bar}░"
        fi
    done
    
    echo -e "  ${_DIM}Confidence:${_NC} ${conf_color}${conf_bar}${_NC} ${confidence}"
    
    # Files
    if [ -n "$files_modified" ] && [ "$files_modified" != "0" ] && [ "$files_modified" != "[]" ]; then
        local file_count=$(echo "$files_modified" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo "?")
        echo -e "  ${_DIM}Files:${_NC}      ${_MAGENTA}${file_count}${_NC} modified"
    fi
    
    # Issues
    if [ -n "$issues_found" ] && [ "$issues_found" != "0" ] && [ "$issues_found" != "[]" ]; then
        local issue_count=$(echo "$issues_found" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo "?")
        if [ "$issue_count" != "0" ] && [ "$issue_count" != "?" ]; then
            echo -e "  ${_DIM}Issues:${_NC}     ${_YELLOW}${issue_count}${_NC} found"
        fi
    fi
    
    # Summary
    if [ -n "$summary" ]; then
        echo ""
        echo -e "  ${_DIM}Summary:${_NC}"
        echo "$summary" | fold -s -w 56 | sed 's/^/    /'
    fi
    
    echo ""
    echo -e "${_DIM}────────────────────────────────────────${_NC}"
}

# ============================================================================
# Quick Status Line
# ============================================================================

# Print a quick one-line status (for use between operations)
progress_status() {
    local message="$1"
    local type="${2:-info}"
    
    local icon=""
    local color=""
    
    case "$type" in
        success) icon="✓"; color="$_GREEN" ;;
        error)   icon="✗"; color="$_RED" ;;
        warn)    icon="⚠"; color="$_YELLOW" ;;
        info)    icon="ℹ"; color="$_BLUE" ;;
        work)    icon="⋯"; color="$_CYAN" ;;
        *)       icon="•"; color="$_DIM" ;;
    esac
    
    echo -e "${color}${icon}${_NC} ${message}"
}
