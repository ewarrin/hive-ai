#!/usr/bin/env bash
# Hive CLI Abstraction Layer
#
# Provides a unified interface for invoking different AI CLI tools:
# - Claude Code (claude -p)
# - OpenAI Codex (codex)
#
# Automatically selects the appropriate CLI based on config and availability.

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"

# Source config if not already loaded
if ! declare -f config_load &>/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
fi

# ============================================================================
# CLI Detection
# ============================================================================

# Check if Claude CLI is available
invoke_claude_available() {
    command -v claude &>/dev/null
}

# Check if Codex CLI is available
invoke_codex_available() {
    command -v codex &>/dev/null
}

# Get list of available CLIs
invoke_list_available() {
    local available=""
    invoke_claude_available && available="$available claude"
    invoke_codex_available && available="$available codex"
    echo "$available" | xargs
}

# ============================================================================
# Model Tier Management
# ============================================================================

# Model tiers for cost-aware downgrade
# Higher tier = more expensive
declare -A MODEL_TIERS 2>/dev/null || true
MODEL_TIER_OPUS=3
MODEL_TIER_SONNET=2
MODEL_TIER_HAIKU=1

# Get tier for a model name
invoke_get_model_tier() {
    local model="$1"
    case "$model" in
        *opus*) echo 3 ;;
        *sonnet*) echo 2 ;;
        *haiku*) echo 1 ;;
        *) echo 2 ;;  # Default to sonnet tier
    esac
}

# Downgrade model to next tier
invoke_downgrade_model() {
    local model="$1"
    local current_tier=$(invoke_get_model_tier "$model")

    case "$current_tier" in
        3) echo "sonnet" ;;
        2) echo "haiku" ;;
        *) echo "$model" ;;  # Can't downgrade further
    esac
}

# ============================================================================
# Agent Invocation
# ============================================================================

# Main function to invoke an agent with the appropriate CLI
# Usage: hive_invoke_agent <agent> <prompt_file> <output_file> [run_id]
hive_invoke_agent() {
    local agent="$1"
    local prompt_file="$2"
    local output_file="$3"
    local run_id="${4:-}"

    # Get CLI and model for this agent
    local cli=$(config_get_agent_cli "$agent")
    local model=$(config_get_agent_model_name "$agent")

    # Check for cost-aware downgrade
    if [ -n "$run_id" ] && [ "${HIVE_COST_AWARE:-0}" = "1" ]; then
        if should_downgrade_model "$run_id" 2>/dev/null; then
            local new_model=$(invoke_downgrade_model "$model")
            if [ "$new_model" != "$model" ]; then
                echo "  [Cost-aware] Downgrading $agent from $model to $new_model" >&2
                model="$new_model"
            fi
        fi
    fi

    # Log the invocation
    echo "  [Invoke] $agent via $cli ($model)" >&2

    # Invoke the appropriate CLI
    case "$cli" in
        claude)
            _invoke_claude "$prompt_file" "$output_file" "$model"
            ;;
        codex)
            if invoke_codex_available && config_codex_enabled; then
                _invoke_codex "$prompt_file" "$output_file" "$model"
            else
                # Fallback to claude
                echo "  [Invoke] Codex not available, falling back to Claude" >&2
                _invoke_claude "$prompt_file" "$output_file" "$model"
            fi
            ;;
        *)
            echo "  [Invoke] Unknown CLI '$cli', using Claude" >&2
            _invoke_claude "$prompt_file" "$output_file" "$model"
            ;;
    esac
}

# ============================================================================
# CLI Implementations
# ============================================================================

# Invoke Claude Code CLI
_invoke_claude() {
    local prompt_file="$1"
    local output_file="$2"
    local model="${3:-sonnet}"

    if ! invoke_claude_available; then
        echo "Error: Claude CLI not found" >&2
        return 1
    fi

    # Build command with model flag if not default
    local cmd="claude -p --dangerously-skip-permissions"

    # Note: claude -p doesn't currently support --model flag in all versions
    # The model is typically configured via the Claude CLI settings
    # If your version supports it, uncomment below:
    # if [ "$model" != "sonnet" ]; then
    #     cmd="$cmd --model $model"
    # fi

    cat "$prompt_file" | $cmd 2>&1 | tee "$output_file"
}

# Invoke OpenAI Codex CLI
_invoke_codex() {
    local prompt_file="$1"
    local output_file="$2"
    local model="${3:-}"

    if ! invoke_codex_available; then
        echo "Error: Codex CLI not found" >&2
        return 1
    fi

    # Build codex command
    local cmd="codex --approval-mode full-auto"

    # Add model if specified
    if [ -n "$model" ]; then
        cmd="$cmd --model $model"
    fi

    # Codex takes input differently - use message file
    $cmd --message-file "$prompt_file" 2>&1 | tee "$output_file"
}

# ============================================================================
# Streaming Support
# ============================================================================

# Invoke with live output streaming (for interactive use)
hive_invoke_agent_stream() {
    local agent="$1"
    local prompt_file="$2"
    local output_file="$3"

    local cli=$(config_get_agent_cli "$agent")
    local model=$(config_get_agent_model_name "$agent")

    case "$cli" in
        claude)
            # Claude streams by default
            _invoke_claude "$prompt_file" "$output_file" "$model"
            ;;
        codex)
            if invoke_codex_available && config_codex_enabled; then
                _invoke_codex "$prompt_file" "$output_file" "$model"
            else
                _invoke_claude "$prompt_file" "$output_file" "$model"
            fi
            ;;
    esac
}

# ============================================================================
# Batch Invocation
# ============================================================================

# Invoke multiple agents in sequence
hive_invoke_batch() {
    local agents="$1"  # Space-separated list
    local prompt_file="$2"
    local output_dir="$3"

    for agent in $agents; do
        local output_file="$output_dir/${agent}.txt"
        echo "Invoking $agent..." >&2
        hive_invoke_agent "$agent" "$prompt_file" "$output_file"
    done
}

# ============================================================================
# CLI Info
# ============================================================================

# Print CLI status and configuration
invoke_print_status() {
    echo ""
    echo "CLI Status"
    echo "=========="
    echo ""

    echo "Available CLIs:"
    if invoke_claude_available; then
        echo "  - claude: $(which claude)"
    else
        echo "  - claude: NOT FOUND"
    fi

    if invoke_codex_available; then
        echo "  - codex: $(which codex)"
    else
        echo "  - codex: NOT FOUND"
    fi

    echo ""
    echo "Codex Enabled: $(config_get '.codex_enabled' 'false')"
    echo ""

    echo "Agent CLI Assignments:"
    for agent in architect implementer tester reviewer security documenter debugger comb; do
        local cli=$(config_get_agent_cli "$agent")
        local model=$(config_get_agent_model_name "$agent")
        printf "  %-12s -> %s (%s)\n" "$agent" "$cli" "$model"
    done
    echo ""
}
