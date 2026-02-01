#!/usr/bin/env bash
# Hive Sub-Agent Orchestration
#
# Allows agents to spawn and coordinate sub-agents for specialized tasks.
# Currently implemented for: Architect → [Complexity Assessor, Data Modeler, File Planner]

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
_SA_RED='\033[0;31m'
_SA_GREEN='\033[0;32m'
_SA_YELLOW='\033[1;33m'
_SA_BLUE='\033[0;34m'
_SA_CYAN='\033[0;36m'
_SA_MAGENTA='\033[0;35m'
_SA_BOLD='\033[1m'
_SA_DIM='\033[2m'
_SA_NC='\033[0m'

# Box drawing characters
_BOX_TL='╭'
_BOX_TR='╮'
_BOX_BL='╰'
_BOX_BR='╯'
_BOX_H='─'
_BOX_V='│'
_BOX_VR='├'
_BOX_VL='┤'

# ============================================================================
# Sub-Agent Registry (Bash 3 compatible)
# ============================================================================

# Get sub-agents for a parent agent
_subagent_registry_get() {
    local agent="$1"
    case "$agent" in
        architect) echo "complexity-assessor data-modeler file-planner" ;;
        *) echo "" ;;
    esac
}

# Get parallel sub-agents for a parent agent
_subagent_parallel_get() {
    local agent="$1"
    case "$agent" in
        architect) echo "data-modeler file-planner" ;;
        *) echo "" ;;
    esac
}

# ============================================================================
# Terminal Helpers
# ============================================================================

_sa_spinner_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_sa_spinner_idx=0

_sa_spinner() {
    echo -n "${_sa_spinner_frames[$_sa_spinner_idx]}"
    _sa_spinner_idx=$(( (_sa_spinner_idx + 1) % 10 ))
}

_sa_format_duration() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    else
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    fi
}

_sa_truncate() {
    local str="$1"
    local max="${2:-40}"
    if [ ${#str} -gt $max ]; then
        echo "${str:0:$((max-3))}..."
    else
        echo "$str"
    fi
}

# ============================================================================
# Sub-Agent Execution
# ============================================================================

subagent_run() {
    local parent="$1"
    local sub_agent="$2"
    local context="$3"
    local output_file="$4"
    
    local prompt_file=""
    if [ -f "$HIVE_DIR/agents/${parent}-sub/${sub_agent}.md" ]; then
        prompt_file="$HIVE_DIR/agents/${parent}-sub/${sub_agent}.md"
    elif [ -f "$HIVE_ROOT/agents/${parent}-sub/${sub_agent}.md" ]; then
        prompt_file="$HIVE_ROOT/agents/${parent}-sub/${sub_agent}.md"
    else
        echo "Sub-agent not found: ${parent}-sub/${sub_agent}" >&2
        return 1
    fi
    
    local system_prompt=$(cat "$prompt_file")
    
    local full_prompt="$system_prompt

---

## Context

$context

---

Analyze the above and provide your output in the specified JSON format."

    echo "$full_prompt" | claude -p --dangerously-skip-permissions 2>&1 > "$output_file"
    
    return $?
}

subagent_extract_json() {
    local output_file="$1"
    
    local json=$(sed -n '/```json/,/```/p' "$output_file" | sed '1d;$d')
    
    if [ -z "$json" ] || ! echo "$json" | jq . >/dev/null 2>&1; then
        json=$(grep -Pzo '\{[\s\S]*\}' "$output_file" 2>/dev/null | tr '\0' '\n' | head -1)
    fi
    
    if echo "$json" | jq . >/dev/null 2>&1; then
        echo "$json"
    else
        echo "{\"error\": \"Failed to parse sub-agent output\"}"
    fi
}

# ============================================================================
# Architect Sub-Agent Orchestration
# ============================================================================

architect_run_subagents() {
    local objective="$1"
    local codebase_index="$2"
    local project_memory="$3"
    local epic_id="$4"
    
    local run_dir="$HIVE_DIR/runs/$(date +%Y%m%d_%H%M%S)_subagents"
    mkdir -p "$run_dir"
    
    local context=$(cat <<EOF
## Objective
$objective

## Codebase Structure
$codebase_index

## Project Memory
$project_memory

## Epic ID
$epic_id
EOF
)
    
    # ─────────────────────────────────────────────────────
    # Header
    # ─────────────────────────────────────────────────────
    
    echo ""
    echo -e "${_SA_CYAN}${_BOX_TL}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_TR}${_SA_NC}"
    echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_BOLD}🔍 Architect Sub-Agents${_SA_NC}                           ${_SA_CYAN}${_BOX_V}${_SA_NC}"
    echo -e "${_SA_CYAN}${_BOX_VR}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_VL}${_SA_NC}"
    
    # ─────────────────────────────────────────────────────
    # Phase 1: Complexity Assessment
    # ─────────────────────────────────────────────────────
    
    echo -ne "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_YELLOW}⋯${_SA_NC} Complexity Assessor                            ${_SA_CYAN}${_BOX_V}${_SA_NC}\r"
    
    local complexity_output="$run_dir/complexity-assessor.txt"
    local complexity_start=$(date +%s)
    
    subagent_run "architect" "complexity-assessor" "$context" "$complexity_output"
    
    local complexity_end=$(date +%s)
    local complexity_duration=$((complexity_end - complexity_start))
    
    local complexity_json=$(subagent_extract_json "$complexity_output")
    local proceed=$(echo "$complexity_json" | jq -r '.proceed // true')
    local scope=$(echo "$complexity_json" | jq -r '.scope // "medium"')
    local est_tasks=$(echo "$complexity_json" | jq -r '.estimated_tasks // "?"')
    local clarity=$(echo "$complexity_json" | jq -r '.clarity // "clear"')
    
    # Color scope indicator
    local scope_color="$_SA_GREEN"
    case "$scope" in
        "large") scope_color="$_SA_YELLOW" ;;
        "too_large") scope_color="$_SA_RED" ;;
    esac
    
    echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_GREEN}✓${_SA_NC} Complexity Assessor   ${_SA_DIM}$(_sa_format_duration $complexity_duration)${_SA_NC}  ${scope_color}■${_SA_NC} ${scope} ${_SA_DIM}(~${est_tasks} tasks)${_SA_NC}   ${_SA_CYAN}${_BOX_V}${_SA_NC}"
    
    # Show warnings if any
    local warnings=$(echo "$complexity_json" | jq -r '.scope_warnings // [] | .[]' 2>/dev/null)
    if [ -n "$warnings" ]; then
        echo "$warnings" | while read -r warning; do
            local trunc=$(_sa_truncate "$warning" 42)
            echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}    ${_SA_YELLOW}⚠${_SA_NC} ${_SA_DIM}$trunc${_SA_NC}   ${_SA_CYAN}${_BOX_V}${_SA_NC}"
        done
    fi
    
    # Check if we should proceed
    if [ "$proceed" = "false" ]; then
        local reason=$(echo "$complexity_json" | jq -r '.proceed_reason // "Scope too large or unclear"')
        echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}                                                    ${_SA_CYAN}${_BOX_V}${_SA_NC}"
        echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_RED}✗${_SA_NC} ${_SA_BOLD}Halting:${_SA_NC} $(_sa_truncate "$reason" 36)   ${_SA_CYAN}${_BOX_V}${_SA_NC}"
        echo -e "${_SA_CYAN}${_BOX_BL}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_BR}${_SA_NC}"
        echo ""
        
        jq -n \
            --argjson complexity "$complexity_json" \
            '{
                proceed: false,
                complexity: $complexity,
                data_model: null,
                file_plan: null
            }'
        return 0
    fi
    
    # ─────────────────────────────────────────────────────
    # Phase 2: Data Modeler + File Planner (parallel)
    # ─────────────────────────────────────────────────────
    
    echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}                                                    ${_SA_CYAN}${_BOX_V}${_SA_NC}"
    
    local data_output="$run_dir/data-modeler.txt"
    local file_output="$run_dir/file-planner.txt"
    
    # Start file planner (always runs)
    echo -ne "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_YELLOW}⋯${_SA_NC} File Planner                                   ${_SA_CYAN}${_BOX_V}${_SA_NC}\r"
    
    local file_start=$(date +%s)
    subagent_run "architect" "file-planner" "$context" "$file_output" &
    local file_pid=$!
    
    # Conditionally start data modeler
    local data_json='{"needs_data_changes": false, "rationale": "Skipped"}'
    local data_pid=""
    local data_duration=0
    local run_data_modeler=false
    
    if echo "$objective" | grep -qiE "database|schema|model|table|store|entity|type|interface|migration|field|column"; then
        run_data_modeler=true
        echo -ne "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_YELLOW}⋯${_SA_NC} Data Modeler                                   ${_SA_CYAN}${_BOX_V}${_SA_NC}\n"
        echo -ne "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_YELLOW}⋯${_SA_NC} File Planner                                   ${_SA_CYAN}${_BOX_V}${_SA_NC}\r\033[A\r"
        
        local data_start=$(date +%s)
        subagent_run "architect" "data-modeler" "$context" "$data_output" &
        data_pid=$!
    fi
    
    # Wait for file planner
    wait $file_pid
    local file_end=$(date +%s)
    local file_duration=$((file_end - file_start))
    local file_json=$(subagent_extract_json "$file_output")
    local new_files=$(echo "$file_json" | jq -r '.new_files | length // 0')
    local mod_files=$(echo "$file_json" | jq -r '.modified_files | length // 0')
    
    # Wait for data modeler if running
    if [ -n "$data_pid" ]; then
        wait $data_pid
        local data_end=$(date +%s)
        data_duration=$((data_end - data_start))
        data_json=$(subagent_extract_json "$data_output")
        local needs_changes=$(echo "$data_json" | jq -r '.needs_data_changes // false')
        local new_types=$(echo "$data_json" | jq -r '.new_types | length // 0')
        local db_changes=$(echo "$data_json" | jq -r '.database_changes | length // 0')
        
        # Data modeler result
        if [ "$needs_changes" = "true" ]; then
            echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_GREEN}✓${_SA_NC} Data Modeler          ${_SA_DIM}$(_sa_format_duration $data_duration)${_SA_NC}  ${_SA_MAGENTA}◆${_SA_NC} ${new_types} types ${_SA_DIM}${db_changes} tables${_SA_NC}   ${_SA_CYAN}${_BOX_V}${_SA_NC}"
        else
            echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_GREEN}✓${_SA_NC} Data Modeler          ${_SA_DIM}$(_sa_format_duration $data_duration)${_SA_NC}  ${_SA_DIM}no changes needed${_SA_NC}   ${_SA_CYAN}${_BOX_V}${_SA_NC}"
        fi
    fi
    
    # File planner result
    echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_GREEN}✓${_SA_NC} File Planner          ${_SA_DIM}$(_sa_format_duration $file_duration)${_SA_NC}  ${_SA_BLUE}+${_SA_NC}${new_files} new ${_SA_YELLOW}~${_SA_NC}${mod_files} modified     ${_SA_CYAN}${_BOX_V}${_SA_NC}"
    
    # Show new files preview
    local file_preview=$(echo "$file_json" | jq -r '.new_files[:3][] | .path' 2>/dev/null)
    if [ -n "$file_preview" ]; then
        echo "$file_preview" | while read -r fpath; do
            local short=$(_sa_truncate "$fpath" 42)
            echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}    ${_SA_DIM}└ $short${_SA_NC}   ${_SA_CYAN}${_BOX_V}${_SA_NC}"
        done
        local total_new=$(echo "$file_json" | jq -r '.new_files | length // 0')
        if [ "$total_new" -gt 3 ]; then
            echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}    ${_SA_DIM}  ... and $((total_new - 3)) more${_SA_NC}                            ${_SA_CYAN}${_BOX_V}${_SA_NC}"
        fi
    fi
    
    # ─────────────────────────────────────────────────────
    # Footer
    # ─────────────────────────────────────────────────────
    
    local total_duration=$((complexity_duration + file_duration + data_duration))
    
    echo -e "${_SA_CYAN}${_BOX_VR}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_VL}${_SA_NC}"
    echo -e "${_SA_CYAN}${_BOX_V}${_SA_NC}  ${_SA_GREEN}●${_SA_NC} Complete in ${_SA_BOLD}$(_sa_format_duration $total_duration)${_SA_NC}                                 ${_SA_CYAN}${_BOX_V}${_SA_NC}"
    echo -e "${_SA_CYAN}${_BOX_BL}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_H}${_BOX_BR}${_SA_NC}"
    echo ""
    
    # Build combined output
    jq -n \
        --argjson complexity "$complexity_json" \
        --argjson data_model "$data_json" \
        --argjson file_plan "$file_json" \
        --arg duration "$total_duration" \
        '{
            proceed: true,
            total_duration_seconds: ($duration | tonumber),
            complexity: $complexity,
            data_model: $data_model,
            file_plan: $file_plan
        }'
}

# ============================================================================
# Context Injection for Parent Agent
# ============================================================================

architect_format_subagent_context() {
    local subagent_results="$1"
    
    local proceed=$(echo "$subagent_results" | jq -r '.proceed')
    
    if [ "$proceed" = "false" ]; then
        local reason=$(echo "$subagent_results" | jq -r '.complexity.proceed_reason // "Unknown"')
        local clarifications=$(echo "$subagent_results" | jq -r '.complexity.clarifications_needed // [] | join("\n- ")')
        local scope_warnings=$(echo "$subagent_results" | jq -r '.complexity.scope_warnings // [] | join("\n- ")')
        
        cat <<EOF
## ⚠️ Sub-Agent Assessment: DO NOT PROCEED

**Reason:** $reason

$([ -n "$clarifications" ] && echo "**Clarifications needed:**
- $clarifications")

$([ -n "$scope_warnings" ] && echo "**Scope warnings:**
- $scope_warnings")

You should either:
1. Ask for clarification on the ambiguous points
2. Recommend splitting this into smaller objectives
3. Flag specific concerns that need human input

Do NOT proceed with a full design.
EOF
        return
    fi
    
    # Format successful sub-agent results
    local scope=$(echo "$subagent_results" | jq -r '.complexity.scope // "medium"')
    local est_tasks=$(echo "$subagent_results" | jq -r '.complexity.estimated_tasks // "?"')
    local clarity=$(echo "$subagent_results" | jq -r '.complexity.clarity // "clear"')
    
    local needs_data=$(echo "$subagent_results" | jq -r '.data_model.needs_data_changes // false')
    
    cat <<EOF
## Sub-Agent Analysis

Your specialist team has analyzed this objective. Use their work as your foundation.

### Scope Assessment
- **Scope:** $scope (~$est_tasks tasks estimated)
- **Clarity:** $clarity

**Risks identified:**
$(echo "$subagent_results" | jq -r '.complexity.risks // [] | .[] | "- **\(.risk)** (impact: \(.impact)) → \(.mitigation)"' 2>/dev/null || echo "- None identified")

**Simplification opportunities:**
$(echo "$subagent_results" | jq -r '.complexity.simplifications // [] | .[] | "- \(.)"' 2>/dev/null || echo "- None identified")

### Data Model
$(if [ "$needs_data" = "true" ]; then
    echo "**New types to create:**"
    echo "$subagent_results" | jq -r '.data_model.new_types // [] | .[] | "- **\(.name)** in `\(.location)` — \(.rationale)"' 2>/dev/null
    echo ""
    echo "**Database changes:**"
    echo "$subagent_results" | jq -r '.data_model.database_changes // [] | .[] | "- \(.type): `\(.table)`"' 2>/dev/null
    echo ""
    local migration_notes=$(echo "$subagent_results" | jq -r '.data_model.migration_notes // ""')
    [ -n "$migration_notes" ] && echo "**Migration notes:** $migration_notes"
else
    echo "_No data model changes needed._"
fi)

### File Structure
**New files to create:**
$(echo "$subagent_results" | jq -r '.file_plan.new_files // [] | .[] | "- `\(.path)` — \(.purpose)"' 2>/dev/null || echo "- None")

**Files to modify:**
$(echo "$subagent_results" | jq -r '.file_plan.modified_files // [] | .[] | "- `\(.path)` — \(.reason)"' 2>/dev/null || echo "- None")

**Conventions to follow:**
$(echo "$subagent_results" | jq -r '.file_plan.conventions_applied // [] | .[] | "- \(.)"' 2>/dev/null || echo "- Match existing patterns")

---

Build on this analysis. You may adjust or override recommendations if you have good reason — but document why in your decisions.
EOF
}

# ============================================================================
# Integration Helpers
# ============================================================================

agent_has_subagents() {
    local agent="$1"
    local subagents=$(_subagent_registry_get "$agent")
    [ -n "$subagents" ]
}

agent_get_subagents() {
    local agent="$1"
    _subagent_registry_get "$agent"
}

run_subagents_for_context() {
    local agent="$1"
    local objective="$2"
    local codebase_index="$3"
    local project_memory="$4"
    local epic_id="$5"
    
    case "$agent" in
        architect)
            local results=$(architect_run_subagents "$objective" "$codebase_index" "$project_memory" "$epic_id")
            architect_format_subagent_context "$results"
            ;;
        *)
            echo ""
            ;;
    esac
}
