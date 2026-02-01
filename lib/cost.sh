#!/usr/bin/env bash
# Hive Cost Tracking - Track token usage and costs
#
# Tracks input/output tokens per agent, estimates costs

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
MEMORY_FILE="$HIVE_DIR/memory.json"

# Pricing per 1M tokens (as of 2024 - update as needed)
# Claude 3.5 Sonnet pricing
COST_INPUT_PER_1M=${HIVE_COST_INPUT:-3.00}    # $3.00 per 1M input tokens
COST_OUTPUT_PER_1M=${HIVE_COST_OUTPUT:-15.00}  # $15.00 per 1M output tokens

# ============================================================================
# Cost File Management
# ============================================================================

_cost_file() {
    local run_id="${1:-current}"
    echo "$HIVE_DIR/runs/$run_id/cost.json"
}

_global_cost_file() {
    echo "$HIVE_DIR/cost_history.json"
}

cost_init() {
    local run_id="$1"
    local cost_file=$(_cost_file "$run_id")
    
    mkdir -p "$(dirname "$cost_file")"
    
    cat > "$cost_file" << EOF
{
  "run_id": "$run_id",
  "started_at": "$(date -Iseconds)",
  "agents": {},
  "total_input_tokens": 0,
  "total_output_tokens": 0,
  "total_cost_usd": 0,
  "sub_agents": {}
}
EOF
}

# ============================================================================
# Token Estimation
# ============================================================================

# Estimate tokens from text (rough: ~4 chars per token for English)
estimate_tokens() {
    local text="$1"
    local char_count=${#text}
    echo $((char_count / 4))
}

# Estimate tokens from a file
estimate_tokens_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local char_count=$(wc -c < "$file" | tr -d ' ')
        echo $((char_count / 4))
    else
        echo 0
    fi
}

# ============================================================================
# Cost Recording
# ============================================================================

# Record usage for an agent
# Usage: cost_record_agent <run_id> <agent> <input_tokens> <output_tokens>
cost_record_agent() {
    local run_id="$1"
    local agent="$2"
    local input_tokens="${3:-0}"
    local output_tokens="${4:-0}"
    local is_subagent="${5:-false}"
    
    local cost_file=$(_cost_file "$run_id")
    
    # Ensure tokens are numbers
    [[ ! "$input_tokens" =~ ^[0-9]+$ ]] && input_tokens=0
    [[ ! "$output_tokens" =~ ^[0-9]+$ ]] && output_tokens=0
    
    # Calculate cost (using awk for portability instead of bc)
    local input_cost=$(awk "BEGIN {printf \"%.6f\", $input_tokens * $COST_INPUT_PER_1M / 1000000}")
    local output_cost=$(awk "BEGIN {printf \"%.6f\", $output_tokens * $COST_OUTPUT_PER_1M / 1000000}")
    local total_cost=$(awk "BEGIN {printf \"%.6f\", $input_cost + $output_cost}")
    
    if [ ! -f "$cost_file" ]; then
        cost_init "$run_id"
    fi
    
    # Update cost file
    local section="agents"
    [ "$is_subagent" = "true" ] && section="sub_agents"
    
    local tmp=$(mktemp)
    jq --arg agent "$agent" \
       --argjson input "$input_tokens" \
       --argjson output "$output_tokens" \
       --argjson cost "$total_cost" \
       --arg section "$section" \
       '
       .[$section][$agent] = {
         input_tokens: ((.[$section][$agent].input_tokens // 0) + $input),
         output_tokens: ((.[$section][$agent].output_tokens // 0) + $output),
         cost_usd: ((.[$section][$agent].cost_usd // 0) + $cost),
         calls: ((.[$section][$agent].calls // 0) + 1)
       } |
       .total_input_tokens += $input |
       .total_output_tokens += $output |
       .total_cost_usd = (.total_cost_usd + $cost | . * 1000000 | floor | . / 1000000)
       ' "$cost_file" > "$tmp" && mv "$tmp" "$cost_file"

    # Update agent cost averages in memory for smart scheduling
    cost_update_agent_average "$agent" "$input_tokens" "$output_tokens" "$total_cost"
}

# Record from prompt file and output file
cost_record_from_files() {
    local run_id="$1"
    local agent="$2"
    local prompt_file="$3"
    local output_file="$4"
    local is_subagent="${5:-false}"
    
    local input_tokens=$(estimate_tokens_file "$prompt_file")
    local output_tokens=$(estimate_tokens_file "$output_file")
    
    cost_record_agent "$run_id" "$agent" "$input_tokens" "$output_tokens" "$is_subagent"
}

# ============================================================================
# Cost Retrieval
# ============================================================================

# Get current run cost
cost_get_run() {
    local run_id="$1"
    local cost_file=$(_cost_file "$run_id")
    
    if [ -f "$cost_file" ]; then
        cat "$cost_file"
    else
        echo "{}"
    fi
}

# Get total cost for current run
cost_get_total() {
    local run_id="$1"
    local cost_file=$(_cost_file "$run_id")
    
    if [ -f "$cost_file" ]; then
        jq -r '.total_cost_usd // 0' "$cost_file"
    else
        echo "0"
    fi
}

# ============================================================================
# Cost Display
# ============================================================================

# Format cost for display
format_cost() {
    local cost="${1:-0}"
    awk -v c="$cost" 'BEGIN {
        if (c < 0.01) printf "%.4f", c
        else if (c < 1) printf "%.3f", c
        else printf "%.2f", c
    }'
}

# Format token count
format_tokens() {
    local tokens="${1:-0}"
    if [ "$tokens" -ge 1000000 ] 2>/dev/null; then
        awk -v t="$tokens" 'BEGIN {printf "%.1fM", t / 1000000}'
    elif [ "$tokens" -ge 1000 ] 2>/dev/null; then
        awk -v t="$tokens" 'BEGIN {printf "%.1fK", t / 1000}'
    else
        echo "$tokens"
    fi
}

# Print cost summary for a run (inline, for end of agent)
cost_print_inline() {
    local run_id="$1"
    local cost_file=$(_cost_file "$run_id")
    
    if [ -f "$cost_file" ]; then
        local total=$(jq -r '.total_cost_usd // 0' "$cost_file")
        local input=$(jq -r '.total_input_tokens // 0' "$cost_file")
        local output=$(jq -r '.total_output_tokens // 0' "$cost_file")
        
        echo -e "\033[2m  💰 $(format_cost $total) ($(format_tokens $input) in / $(format_tokens $output) out)\033[0m"
    fi
}

# Print detailed cost breakdown
cost_print_detailed() {
    local run_id="$1"
    local cost_file=$(_cost_file "$run_id")
    
    if [ ! -f "$cost_file" ]; then
        echo "No cost data for run: $run_id"
        return
    fi
    
    local data=$(cat "$cost_file")
    
    local CYAN='\033[0;36m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local DIM='\033[2m'
    local BOLD='\033[1m'
    local NC='\033[0m'
    
    echo ""
    echo -e "${BOLD}💰 Cost Breakdown${NC}"
    echo -e "${DIM}─────────────────${NC}"
    echo ""
    
    # Agents
    echo -e "${BOLD}Agents:${NC}"
    echo "$data" | jq -r '
        .agents | to_entries[] |
        "  \(.key): $\(.value.cost_usd | . * 10000 | floor | . / 10000) (\(.value.input_tokens) in / \(.value.output_tokens) out) x\(.value.calls)"
    ' 2>/dev/null | while read line; do
        echo -e "  $line"
    done
    
    # Sub-agents
    local sub_count=$(echo "$data" | jq '.sub_agents | length' 2>/dev/null || echo "0")
    if [ "$sub_count" -gt 0 ]; then
        echo ""
        echo -e "${BOLD}Sub-Agents:${NC}"
        echo "$data" | jq -r '
            .sub_agents | to_entries[] |
            "  \(.key): $\(.value.cost_usd | . * 10000 | floor | . / 10000) (\(.value.input_tokens) in / \(.value.output_tokens) out) x\(.value.calls)"
        ' 2>/dev/null | while read line; do
            echo -e "  ${DIM}$line${NC}"
        done
    fi
    
    echo ""
    echo -e "${DIM}─────────────────${NC}"
    
    local total_input=$(echo "$data" | jq -r '.total_input_tokens // 0')
    local total_output=$(echo "$data" | jq -r '.total_output_tokens // 0')
    local total_cost=$(echo "$data" | jq -r '.total_cost_usd // 0')
    
    echo -e "  ${DIM}Input:${NC}  $(format_tokens $total_input) tokens"
    echo -e "  ${DIM}Output:${NC} $(format_tokens $total_output) tokens"
    echo ""
    echo -e "  ${BOLD}Total:  ${GREEN}$(format_cost $total_cost)${NC}"
    echo ""
}

# ============================================================================
# Smart Orchestrator - Agent Cost Tracking
# ============================================================================

# Update running average for agent costs in memory
cost_update_agent_average() {
    local agent="$1"
    local input_tokens="$2"
    local output_tokens="$3"
    local cost="$4"

    [ ! -f "$MEMORY_FILE" ] && return 0

    local mem=$(cat "$MEMORY_FILE")
    echo "$mem" | jq --arg a "$agent" \
        --argjson i "$input_tokens" --argjson o "$output_tokens" --argjson c "$cost" '
        .agent_costs[$a] = {
            avg_input: (((.agent_costs[$a].avg_input // 0) * (.agent_costs[$a].runs // 0) + $i) / ((.agent_costs[$a].runs // 0) + 1)),
            avg_output: (((.agent_costs[$a].avg_output // 0) * (.agent_costs[$a].runs // 0) + $o) / ((.agent_costs[$a].runs // 0) + 1)),
            avg_cost: (((.agent_costs[$a].avg_cost // 0) * (.agent_costs[$a].runs // 0) + $c) / ((.agent_costs[$a].runs // 0) + 1)),
            runs: ((.agent_costs[$a].runs // 0) + 1)
        }
    ' > "$MEMORY_FILE"
}

# Get estimated cost for an agent
cost_get_agent_estimate() {
    local agent="$1"

    if [ -f "$MEMORY_FILE" ]; then
        cat "$MEMORY_FILE" | jq -r --arg a "$agent" '.agent_costs[$a].avg_cost // 0.20'
    else
        echo "0.20"
    fi
}

# Check if running agent fits within remaining budget
cost_fits_budget() {
    local agent="$1"
    local spent="$2"
    local budget="${HIVE_COST_BUDGET:-0}"

    [ "$budget" = "0" ] && return 0  # No budget = always fits

    local estimate=$(cost_get_agent_estimate "$agent")
    local remaining=$(awk -v b="$budget" -v s="$spent" 'BEGIN {print b - s}')
    local fits=$(awk -v e="$estimate" -v r="$remaining" 'BEGIN {print (e <= r) ? 1 : 0}')

    [ "$fits" = "1" ]
}

# Estimate total workflow cost
cost_estimate_workflow() {
    local workflow_type="$1"

    # Need workflow.sh sourced for this
    local phases=$(workflow_get "$workflow_type" 2>/dev/null | jq -r '.phases[].agent // empty' 2>/dev/null)
    local total=0

    for agent in $phases; do
        local est=$(cost_get_agent_estimate "$agent")
        total=$(awk -v t="$total" -v e="$est" 'BEGIN {print t + e}')
    done

    echo "$total"
}

# Check if we should downgrade model to save costs
# Used by invoke.sh for cost-aware model selection
should_downgrade_model() {
    local run_id="$1"
    local budget="${HIVE_COST_BUDGET:-0}"

    # No budget = no downgrade needed
    [ "$budget" = "0" ] && return 1

    # Get current spend
    local spent=$(cost_get_total "$run_id")

    # Check if we've spent more than 60% of budget - start downgrading
    local threshold=$(awk -v b="$budget" 'BEGIN {printf "%.2f", b * 0.6}')
    local should=$(awk -v s="$spent" -v t="$threshold" 'BEGIN {print (s >= t) ? 1 : 0}')

    [ "$should" = "1" ]
}

# ============================================================================
# History
# ============================================================================

# Save run cost to history
cost_save_to_history() {
    local run_id="$1"
    local cost_file=$(_cost_file "$run_id")
    local history_file=$(_global_cost_file)
    
    if [ ! -f "$cost_file" ]; then
        return
    fi
    
    # Initialize history if needed
    if [ ! -f "$history_file" ]; then
        echo '{"runs": [], "total_cost_usd": 0}' > "$history_file"
    fi
    
    local run_data=$(cat "$cost_file")
    local run_cost=$(echo "$run_data" | jq -r '.total_cost_usd // 0')
    
    local tmp=$(mktemp)
    jq --argjson run "$run_data" \
       --argjson cost "$run_cost" \
       '.runs += [$run] | .total_cost_usd += $cost' \
       "$history_file" > "$tmp" && mv "$tmp" "$history_file"
}

# Get total historical cost
cost_get_historical_total() {
    local history_file=$(_global_cost_file)
    
    if [ -f "$history_file" ]; then
        jq -r '.total_cost_usd // 0' "$history_file"
    else
        echo "0"
    fi
}

# Print cost history summary
cost_print_history() {
    local history_file=$(_global_cost_file)
    
    if [ ! -f "$history_file" ]; then
        echo "No cost history found."
        return
    fi
    
    local CYAN='\033[0;36m'
    local GREEN='\033[0;32m'
    local DIM='\033[2m'
    local BOLD='\033[1m'
    local NC='\033[0m'
    
    local data=$(cat "$history_file")
    local total=$(echo "$data" | jq -r '.total_cost_usd // 0')
    local run_count=$(echo "$data" | jq -r '.runs | length')
    
    echo ""
    echo -e "${BOLD}📊 Cost History${NC}"
    echo -e "${DIM}───────────────${NC}"
    echo ""
    echo -e "  ${DIM}Total runs:${NC}  $run_count"
    echo -e "  ${DIM}Total cost:${NC}  ${GREEN}$(format_cost $total)${NC}"
    
    if [ "$run_count" -gt 0 ]; then
        local avg=$(awk -v t="$total" -v n="$run_count" 'BEGIN {printf "%.4f", t / n}')
        echo -e "  ${DIM}Avg/run:${NC}     $(format_cost $avg)"
    fi
    
    echo ""
    echo -e "${BOLD}Recent runs:${NC}"
    echo "$data" | jq -r '
        .runs | .[-5:][] |
        "  \(.run_id): $\(.total_cost_usd | . * 10000 | floor | . / 10000)"
    ' 2>/dev/null
    echo ""
}
