#!/usr/bin/env bash
# Hive Configuration Management
#
# Manages .hive/config.json for project-level settings including:
# - Model configuration per agent
# - CLI backend selection (claude, codex)
# - Feature flags

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
CONFIG_FILE="$HIVE_DIR/config.json"

# ============================================================================
# Default Configuration
# ============================================================================

# Generate default config JSON
_config_default() {
    cat <<'EOF'
{
  "version": 1,
  "codex_enabled": false,
  "models": {
    "default": {
      "cli": "claude",
      "model": "sonnet"
    },
    "architect": {
      "cli": "claude",
      "model": "sonnet"
    },
    "implementer": {
      "cli": "claude",
      "model": "sonnet"
    },
    "tester": {
      "cli": "claude",
      "model": "sonnet"
    },
    "reviewer": {
      "cli": "claude",
      "model": "sonnet"
    },
    "security": {
      "cli": "claude",
      "model": "sonnet"
    },
    "documenter": {
      "cli": "claude",
      "model": "sonnet"
    },
    "debugger": {
      "cli": "claude",
      "model": "sonnet"
    },
    "comb": {
      "cli": "claude",
      "model": "sonnet"
    }
  },
  "features": {
    "worktree_parallel": true,
    "confidence_checkpoint": true,
    "cost_aware": false,
    "fast_mode": false,
    "adapt_enabled": true
  }
}
EOF
}

# ============================================================================
# Core Functions
# ============================================================================

# Initialize config file if it doesn't exist
config_init() {
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p "$HIVE_DIR"
        _config_default > "$CONFIG_FILE"
    fi
}

# Load and return full config
config_load() {
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        config_init
        cat "$CONFIG_FILE"
    fi
}

# Get a config value by jq path
# Usage: config_get ".models.architect.cli"
config_get() {
    local path="$1"
    local default="${2:-}"

    local value=$(config_load | jq -r "$path // empty" 2>/dev/null)

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Set a config value by jq path
# Usage: config_set ".models.architect.model" "opus"
config_set() {
    local path="$1"
    local value="$2"

    config_init

    local current=$(config_load)

    # Determine if value is a string or other type
    if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" ]] || [[ "$value" == "false" ]] || [[ "$value" == "null" ]]; then
        echo "$current" | jq "$path = $value" > "$CONFIG_FILE"
    else
        echo "$current" | jq "$path = \"$value\"" > "$CONFIG_FILE"
    fi
}

# ============================================================================
# Model Configuration
# ============================================================================

# Check if codex is enabled in config
config_codex_enabled() {
    local enabled=$(config_get ".codex_enabled" "false")
    [ "$enabled" = "true" ]
}

# Check if codex CLI is available
config_codex_available() {
    command -v codex &>/dev/null
}

# Get model config for a specific agent
# Returns JSON: {"cli": "claude", "model": "sonnet"}
config_get_agent_model() {
    local agent="$1"

    local config=$(config_load)

    # Try agent-specific config first
    local agent_config=$(echo "$config" | jq -c ".models.\"$agent\" // empty" 2>/dev/null)

    if [ -n "$agent_config" ] && [ "$agent_config" != "null" ] && [ "$agent_config" != "{}" ]; then
        echo "$agent_config"
    else
        # Fall back to default
        echo "$config" | jq -c '.models.default // {"cli": "claude", "model": "sonnet"}'
    fi
}

# Get the CLI to use for an agent (claude or codex)
config_get_agent_cli() {
    local agent="$1"

    local model_config=$(config_get_agent_model "$agent")
    local cli=$(echo "$model_config" | jq -r '.cli // "claude"')

    # If codex is requested but not enabled or available, fall back to claude
    if [ "$cli" = "codex" ]; then
        if ! config_codex_enabled; then
            cli="claude"
        elif ! config_codex_available; then
            cli="claude"
        fi
    fi

    echo "$cli"
}

# Get the model to use for an agent
config_get_agent_model_name() {
    local agent="$1"

    local model_config=$(config_get_agent_model "$agent")
    echo "$model_config" | jq -r '.model // "sonnet"'
}

# ============================================================================
# Feature Flags
# ============================================================================

# Check if a feature is enabled
config_feature_enabled() {
    local feature="$1"
    local default="${2:-false}"

    local enabled=$(config_get ".features.$feature" "$default")
    [ "$enabled" = "true" ]
}

# ============================================================================
# Config Migration
# ============================================================================

# Migrate config to latest version
config_migrate() {
    [ ! -f "$CONFIG_FILE" ] && return 0

    local current=$(config_load)
    local version=$(echo "$current" | jq -r '.version // 0')

    # v1: Add features section if missing
    if [ "$version" -lt 1 ]; then
        echo "$current" | jq '
            .version = 1 |
            .features = (.features // {
                worktree_parallel: true,
                confidence_checkpoint: true,
                cost_aware: false,
                fast_mode: false,
                adapt_enabled: true
            }) |
            .codex_enabled = (.codex_enabled // false)
        ' > "$CONFIG_FILE"
    fi
}

# ============================================================================
# Config Display
# ============================================================================

# Print current config in a readable format
config_print() {
    local config=$(config_load)

    echo ""
    echo "Hive Configuration"
    echo "=================="
    echo ""

    echo "Codex Enabled: $(config_get '.codex_enabled' 'false')"
    echo ""

    echo "Model Configuration:"
    echo "$config" | jq -r '.models | to_entries[] | "  \(.key): \(.value.cli) (\(.value.model))"'
    echo ""

    echo "Features:"
    echo "$config" | jq -r '.features | to_entries[] | "  \(.key): \(.value)"'
    echo ""
}

# ============================================================================
# Enable/Disable Codex
# ============================================================================

# Enable codex for specific agents or all
config_enable_codex() {
    local agents="${1:-all}"

    config_set ".codex_enabled" "true"

    if [ "$agents" = "all" ]; then
        # Enable codex for implementer and documenter by default
        config_set ".models.implementer.cli" "codex"
        config_set ".models.documenter.cli" "codex"
    else
        for agent in $agents; do
            config_set ".models.$agent.cli" "codex"
        done
    fi

    echo "Codex enabled"
}

# Disable codex entirely
config_disable_codex() {
    config_set ".codex_enabled" "false"

    # Reset all agents to claude
    local config=$(config_load)
    echo "$config" | jq '
        .models |= with_entries(.value.cli = "claude")
    ' > "$CONFIG_FILE"

    echo "Codex disabled - all agents using Claude"
}
