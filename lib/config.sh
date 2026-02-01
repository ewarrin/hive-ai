#!/usr/bin/env bash
# Hive Configuration Management
#
# Supports two config formats:
# 1. Simple format: hive.config.json at project root (preferred, easy to edit)
# 2. Legacy format: .hive/config.json (full control, auto-generated)
#
# The simple format is automatically translated to the internal format.

# ============================================================================
# Configuration Paths
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"

# Config file priority (first found wins):
# 1. ./hive.config.json (project root, simple format)
# 2. ./.hive/config.json (project local, legacy format)
# 3. ~/.hive/hive.config.json (global default, simple format)

ROOT_CONFIG_FILE="hive.config.json"
LEGACY_CONFIG_FILE="$HIVE_DIR/config.json"
GLOBAL_CONFIG_FILE="$HIVE_ROOT/hive.config.json"

# ============================================================================
# Simple Format Example (hive.config.json)
# ============================================================================
#
# {
#   "models": {
#     "default": "sonnet",
#     "architect": "opus",
#     "reviewer": "opus"
#   },
#   "features": {
#     "testing_required": true,
#     "parallel_worktrees": true
#   },
#   "cli_overrides": {
#     "implementer": "codex"
#   }
# }
#
# ============================================================================

# ============================================================================
# Config Detection
# ============================================================================

# Find which config file to use
_config_find_file() {
    if [ -f "$ROOT_CONFIG_FILE" ]; then
        echo "$ROOT_CONFIG_FILE"
    elif [ -f "$LEGACY_CONFIG_FILE" ]; then
        echo "$LEGACY_CONFIG_FILE"
    elif [ -f "$GLOBAL_CONFIG_FILE" ]; then
        echo "$GLOBAL_CONFIG_FILE"
    else
        echo ""
    fi
}

# Check if config is simple format (has flat model strings) or legacy format
_config_is_simple_format() {
    local file="$1"
    [ ! -f "$file" ] && return 1

    # Simple format has models as strings, legacy has them as objects
    local first_model=$(jq -r '.models.default // empty' "$file" 2>/dev/null)

    # If it's a string like "sonnet", it's simple format
    # If it's an object or empty, it's legacy format
    if [ -n "$first_model" ] && [[ ! "$first_model" =~ ^\{ ]]; then
        return 0  # Simple format
    else
        return 1  # Legacy format
    fi
}

# ============================================================================
# Default Configuration (Simple Format)
# ============================================================================

_config_default_simple() {
    cat <<'EOF'
{
  "models": {
    "default": "sonnet",
    "architect": "sonnet",
    "implementer": "sonnet",
    "reviewer": "sonnet",
    "tester": "sonnet",
    "e2e-tester": "sonnet",
    "browser-validator": "sonnet",
    "debugger": "sonnet",
    "security": "sonnet",
    "documenter": "sonnet"
  },
  "features": {
    "testing_required": true,
    "parallel_worktrees": true,
    "auto_mode": false,
    "cost_tracking": false
  },
  "cli_overrides": {}
}
EOF
}

# Legacy format default (for backwards compatibility)
_config_default_legacy() {
    cat <<'EOF'
{
  "version": 1,
  "codex_enabled": false,
  "models": {
    "default": {"cli": "claude", "model": "sonnet"},
    "architect": {"cli": "claude", "model": "sonnet"},
    "implementer": {"cli": "claude", "model": "sonnet"},
    "tester": {"cli": "claude", "model": "sonnet"},
    "reviewer": {"cli": "claude", "model": "sonnet"},
    "security": {"cli": "claude", "model": "sonnet"},
    "documenter": {"cli": "claude", "model": "sonnet"},
    "debugger": {"cli": "claude", "model": "sonnet"},
    "comb": {"cli": "claude", "model": "sonnet"}
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

# Initialize config - creates simple format at project root if none exists
config_init() {
    local config_file=$(_config_find_file)

    if [ -z "$config_file" ]; then
        # No config found - create simple format at project root
        _config_default_simple > "$ROOT_CONFIG_FILE"
        echo "Created hive.config.json - edit to customize models and features"
    fi
}

# Load raw config from file
_config_load_raw() {
    local config_file=$(_config_find_file)

    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        cat "$config_file"
    else
        _config_default_simple
    fi
}

# Load config and normalize to internal format
config_load() {
    local config_file=$(_config_find_file)
    local raw_config=$(_config_load_raw)

    # Check format and convert if needed
    if [ -n "$config_file" ] && _config_is_simple_format "$config_file"; then
        # Convert simple format to internal format
        _config_simple_to_internal "$raw_config"
    else
        # Already in legacy/internal format
        echo "$raw_config"
    fi
}

# Convert simple format to internal format
_config_simple_to_internal() {
    local simple_config="$1"

    # Extract values from simple config
    local default_model=$(echo "$simple_config" | jq -r '.models.default // "sonnet"')

    # Build internal format
    echo "$simple_config" | jq --arg default "$default_model" '
    {
        version: 1,
        codex_enabled: ((.cli_overrides | length) > 0),
        models: (
            .models | to_entries | map({
                key: .key,
                value: {
                    cli: (if $ARGS.named[.key] then $ARGS.named[.key] else "claude" end),
                    model: (if .value then .value else $default end)
                }
            }) | from_entries
        ),
        features: {
            worktree_parallel: (.features.parallel_worktrees // true),
            confidence_checkpoint: true,
            cost_aware: (.features.cost_tracking // false),
            fast_mode: false,
            adapt_enabled: true,
            testing_required: (.features.testing_required // true)
        }
    }
    ' --argjson overrides "$(echo "$simple_config" | jq '.cli_overrides // {}')" 2>/dev/null || echo "$simple_config"
}

# Get a config value by jq path
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

# Set a config value - writes to the appropriate config file
config_set() {
    local path="$1"
    local value="$2"

    local config_file=$(_config_find_file)
    [ -z "$config_file" ] && config_file="$ROOT_CONFIG_FILE"

    local current=$(cat "$config_file" 2>/dev/null || _config_default_simple)
    local tmp_file=$(mktemp)

    # Determine if value is a string or other type
    if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" ]] || [[ "$value" == "false" ]] || [[ "$value" == "null" ]]; then
        echo "$current" | jq "$path = $value" > "$tmp_file"
    else
        echo "$current" | jq "$path = \"$value\"" > "$tmp_file"
    fi

    # Only overwrite if jq succeeded
    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$config_file"
    else
        rm -f "$tmp_file"
    fi
}

# ============================================================================
# Model Configuration (Simple API)
# ============================================================================

# Get the model for an agent (returns: sonnet, opus, haiku)
config_get_model() {
    local agent="$1"

    local config_file=$(_config_find_file)

    if [ -n "$config_file" ] && _config_is_simple_format "$config_file"; then
        # Simple format - direct lookup
        local model=$(jq -r ".models.\"$agent\" // .models.default // \"sonnet\"" "$config_file" 2>/dev/null)
        echo "$model"
    else
        # Legacy format
        config_get_agent_model_name "$agent"
    fi
}

# Set the model for an agent
config_set_model() {
    local agent="$1"
    local model="$2"

    local config_file=$(_config_find_file)
    [ -z "$config_file" ] && config_file="$ROOT_CONFIG_FILE"

    if _config_is_simple_format "$config_file" 2>/dev/null; then
        # Simple format
        config_set ".models.\"$agent\"" "$model"
    else
        # Legacy format
        config_set ".models.\"$agent\".model" "$model"
    fi
}

# Get CLI for an agent (returns: claude, codex)
config_get_cli() {
    local agent="$1"

    local config_file=$(_config_find_file)

    if [ -n "$config_file" ] && _config_is_simple_format "$config_file"; then
        # Simple format - check cli_overrides
        local cli=$(jq -r ".cli_overrides.\"$agent\" // \"claude\"" "$config_file" 2>/dev/null)

        # Verify codex is available if requested
        if [ "$cli" = "codex" ] && ! command -v codex &>/dev/null; then
            cli="claude"
        fi
        echo "$cli"
    else
        # Legacy format
        config_get_agent_cli "$agent"
    fi
}

# ============================================================================
# Legacy Model Configuration (for backwards compatibility)
# ============================================================================

config_codex_enabled() {
    local enabled=$(config_get ".codex_enabled" "false")
    [ "$enabled" = "true" ]
}

config_codex_available() {
    command -v codex &>/dev/null
}

config_get_agent_model() {
    local agent="$1"
    local config=$(config_load)
    local agent_config=$(echo "$config" | jq -c ".models.\"$agent\" // empty" 2>/dev/null)

    if [ -n "$agent_config" ] && [ "$agent_config" != "null" ] && [ "$agent_config" != "{}" ]; then
        echo "$agent_config"
    else
        echo "$config" | jq -c '.models.default // {"cli": "claude", "model": "sonnet"}'
    fi
}

config_get_agent_cli() {
    local agent="$1"
    local model_config=$(config_get_agent_model "$agent")
    local cli=$(echo "$model_config" | jq -r '.cli // "claude"')

    if [ "$cli" = "codex" ]; then
        if ! config_codex_enabled; then
            cli="claude"
        elif ! config_codex_available; then
            cli="claude"
        fi
    fi
    echo "$cli"
}

config_get_agent_model_name() {
    local agent="$1"
    local model_config=$(config_get_agent_model "$agent")
    echo "$model_config" | jq -r '.model // "sonnet"'
}

# ============================================================================
# Feature Flags
# ============================================================================

config_feature_enabled() {
    local feature="$1"
    local default="${2:-false}"

    local config_file=$(_config_find_file)

    if [ -n "$config_file" ] && _config_is_simple_format "$config_file"; then
        # Map simple feature names to internal names
        case "$feature" in
            worktree_parallel) feature="parallel_worktrees" ;;
            cost_aware) feature="cost_tracking" ;;
        esac
        local enabled=$(jq -r ".features.$feature // $default" "$config_file" 2>/dev/null)
    else
        local enabled=$(config_get ".features.$feature" "$default")
    fi

    [ "$enabled" = "true" ]
}

# ============================================================================
# Config Display
# ============================================================================

config_print() {
    local config_file=$(_config_find_file)

    echo ""
    echo "Hive Configuration"
    echo "=================="

    if [ -n "$config_file" ]; then
        echo "Config file: $config_file"
    else
        echo "Config file: (using defaults)"
    fi
    echo ""

    if [ -n "$config_file" ] && _config_is_simple_format "$config_file"; then
        # Simple format display
        echo "Models:"
        jq -r '.models | to_entries[] | "  \(.key): \(.value)"' "$config_file" 2>/dev/null
        echo ""

        echo "Features:"
        jq -r '.features | to_entries[] | "  \(.key): \(.value)"' "$config_file" 2>/dev/null
        echo ""

        local overrides=$(jq -r '.cli_overrides | length' "$config_file" 2>/dev/null)
        if [ "$overrides" -gt 0 ] 2>/dev/null; then
            echo "CLI Overrides:"
            jq -r '.cli_overrides | to_entries[] | "  \(.key): \(.value)"' "$config_file" 2>/dev/null
            echo ""
        fi
    else
        # Legacy format display
        local config=$(config_load)
        echo "Codex Enabled: $(config_get '.codex_enabled' 'false')"
        echo ""
        echo "Model Configuration:"
        echo "$config" | jq -r '.models | to_entries[] | "  \(.key): \(.value.cli) (\(.value.model))"'
        echo ""
        echo "Features:"
        echo "$config" | jq -r '.features | to_entries[] | "  \(.key): \(.value)"'
        echo ""
    fi
}

# ============================================================================
# Quick Config Commands
# ============================================================================

# Set all agents to a specific model
config_set_all_models() {
    local model="$1"

    local config_file=$(_config_find_file)
    [ -z "$config_file" ] && config_file="$ROOT_CONFIG_FILE"

    local current=$(cat "$config_file")
    local tmp_file=$(mktemp)

    if _config_is_simple_format "$config_file" 2>/dev/null; then
        echo "$current" | jq --arg m "$model" '.models |= with_entries(.value = $m)' > "$tmp_file"
    else
        echo "$current" | jq --arg m "$model" '.models |= with_entries(.value.model = $m)' > "$tmp_file"
    fi

    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$config_file"
    else
        rm -f "$tmp_file"
    fi

    echo "All agents set to: $model"
}

# Use opus for planning agents (architect, reviewer, security)
config_use_opus_for_planning() {
    config_set_model "architect" "opus"
    config_set_model "reviewer" "opus"
    config_set_model "security" "opus"
    echo "Planning agents (architect, reviewer, security) set to opus"
}

# Use sonnet for everything (cost-effective)
config_use_sonnet_all() {
    config_set_all_models "sonnet"
}

# Use haiku for fast iteration
config_use_haiku_all() {
    config_set_all_models "haiku"
}

# ============================================================================
# Enable/Disable Codex (Legacy API)
# ============================================================================

config_enable_codex() {
    local agents="${1:-all}"

    local config_file=$(_config_find_file)
    [ -z "$config_file" ] && config_file="$ROOT_CONFIG_FILE"

    if _config_is_simple_format "$config_file" 2>/dev/null; then
        if [ "$agents" = "all" ]; then
            config_set ".cli_overrides.implementer" "codex"
            config_set ".cli_overrides.documenter" "codex"
        else
            for agent in $agents; do
                config_set ".cli_overrides.$agent" "codex"
            done
        fi
    else
        config_set ".codex_enabled" "true"
        if [ "$agents" = "all" ]; then
            config_set ".models.implementer.cli" "codex"
            config_set ".models.documenter.cli" "codex"
        else
            for agent in $agents; do
                config_set ".models.$agent.cli" "codex"
            done
        fi
    fi
    echo "Codex enabled"
}

config_disable_codex() {
    local config_file=$(_config_find_file)
    [ -z "$config_file" ] && return

    local current=$(cat "$config_file")
    local tmp_file=$(mktemp)

    if _config_is_simple_format "$config_file" 2>/dev/null; then
        echo "$current" | jq '.cli_overrides = {}' > "$tmp_file"
    else
        config_set ".codex_enabled" "false"
        current=$(cat "$config_file")
        echo "$current" | jq '.models |= with_entries(.value.cli = "claude")' > "$tmp_file"
    fi

    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$config_file"
    else
        rm -f "$tmp_file"
    fi

    echo "Codex disabled - all agents using Claude"
}

# ============================================================================
# Migration
# ============================================================================

config_migrate() {
    local config_file=$(_config_find_file)
    [ -z "$config_file" ] && return 0

    # Only migrate legacy format
    if ! _config_is_simple_format "$config_file"; then
        local current=$(cat "$config_file")
        local version=$(echo "$current" | jq -r '.version // 0')

        if [ "$version" -lt 1 ]; then
            local tmp_file=$(mktemp)
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
            ' > "$tmp_file"

            if [ -s "$tmp_file" ]; then
                mv "$tmp_file" "$config_file"
            else
                rm -f "$tmp_file"
            fi
        fi
    fi
}
