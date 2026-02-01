#!/usr/bin/env bash
# Hive Tracing - Correlation IDs and span tracking for observability
#
# Provides distributed tracing primitives:
# - trace_id: Unique ID for entire workflow run
# - span_id: Unique ID for each operation (phase, agent, etc.)
# - parent_span_id: Links child operations to parents
# - Duration tracking for each span

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"

# Current trace context (set by trace_init, used by all functions)
_HIVE_TRACE_ID=""
_HIVE_CURRENT_SPAN_ID=""
_HIVE_PARENT_SPAN_ID=""

# ============================================================================
# ID Generation (Bash 3.x compatible)
# ============================================================================

# Generate a unique trace ID
_trace_generate_id() {
    local prefix="${1:-trace}"
    # Use /dev/urandom for randomness, fall back to date+pid if unavailable
    if [ -r /dev/urandom ]; then
        local random=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
        echo "${prefix}-${random}"
    else
        echo "${prefix}-$(date +%s%N)-$$"
    fi
}

# ============================================================================
# Trace Context Management
# ============================================================================

# Initialize tracing for a new run
# Usage: trace_init [run_id]
trace_init() {
    local run_id="${1:-}"

    _HIVE_TRACE_ID=$(_trace_generate_id "trace")
    _HIVE_CURRENT_SPAN_ID=""
    _HIVE_PARENT_SPAN_ID=""

    # Create trace state directory
    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"
    mkdir -p "$trace_dir"

    # Initialize spans file
    echo '[]' > "$trace_dir/spans.json"

    # Store trace_id for persistence
    echo "$_HIVE_TRACE_ID" > "$trace_dir/trace_id"

    # Export for child processes
    export HIVE_TRACE_ID="$_HIVE_TRACE_ID"

    echo "$_HIVE_TRACE_ID"
}

# Load trace context from environment or file
# Usage: trace_load [run_id]
trace_load() {
    local run_id="${1:-}"

    # Try environment first
    if [ -n "$HIVE_TRACE_ID" ]; then
        _HIVE_TRACE_ID="$HIVE_TRACE_ID"
        return 0
    fi

    # Try file
    local trace_file="$HIVE_DIR/runs/$run_id/.trace/trace_id"
    if [ -f "$trace_file" ]; then
        _HIVE_TRACE_ID=$(cat "$trace_file")
        export HIVE_TRACE_ID="$_HIVE_TRACE_ID"
        return 0
    fi

    return 1
}

# Get current trace context as JSON
# Usage: trace_context
trace_context() {
    jq -cn \
        --arg trace_id "${_HIVE_TRACE_ID:-}" \
        --arg span_id "${_HIVE_CURRENT_SPAN_ID:-}" \
        --arg parent_span_id "${_HIVE_PARENT_SPAN_ID:-}" \
        '{
            trace_id: (if $trace_id != "" then $trace_id else null end),
            span_id: (if $span_id != "" then $span_id else null end),
            parent_span_id: (if $parent_span_id != "" then $parent_span_id else null end)
        }'
}

# Get just the trace_id
trace_get_id() {
    echo "${_HIVE_TRACE_ID:-}"
}

# Get current span_id
trace_get_span() {
    echo "${_HIVE_CURRENT_SPAN_ID:-}"
}

# ============================================================================
# Span Management
# ============================================================================

# Start a new span
# Usage: span_start <operation_name> [run_id]
# Returns: span_id
span_start() {
    local operation="$1"
    local run_id="${2:-}"

    # Generate new span ID
    local span_id=$(_trace_generate_id "span")
    local start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))

    # Save parent before updating current
    _HIVE_PARENT_SPAN_ID="$_HIVE_CURRENT_SPAN_ID"
    _HIVE_CURRENT_SPAN_ID="$span_id"

    # Record span start
    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"
    mkdir -p "$trace_dir"

    # Store span metadata for later completion
    local span_file="$trace_dir/${span_id}.json"
    jq -n \
        --arg span_id "$span_id" \
        --arg trace_id "$_HIVE_TRACE_ID" \
        --arg parent_span_id "${_HIVE_PARENT_SPAN_ID:-}" \
        --arg operation "$operation" \
        --arg start_time "$start_time" \
        --arg start_ms "$start_ms" \
        '{
            span_id: $span_id,
            trace_id: $trace_id,
            parent_span_id: (if $parent_span_id != "" then $parent_span_id else null end),
            operation: $operation,
            start_time: $start_time,
            start_ms: ($start_ms | tonumber),
            status: "running",
            end_time: null,
            duration_ms: null,
            tags: {}
        }' > "$span_file"

    # Export for child processes
    export HIVE_CURRENT_SPAN_ID="$span_id"
    export HIVE_PARENT_SPAN_ID="${_HIVE_PARENT_SPAN_ID:-}"

    echo "$span_id"
}

# End a span and record duration
# Usage: span_end <span_id> [status] [run_id]
span_end() {
    local span_id="$1"
    local status="${2:-complete}"
    local run_id="${3:-}"

    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local end_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))

    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"
    local span_file="$trace_dir/${span_id}.json"

    if [ ! -f "$span_file" ]; then
        return 1
    fi

    # Calculate duration and update span
    local span=$(cat "$span_file")
    local start_ms=$(echo "$span" | jq -r '.start_ms')
    local duration_ms=$((end_ms - start_ms))

    echo "$span" | jq \
        --arg end_time "$end_time" \
        --argjson duration_ms "$duration_ms" \
        --arg status "$status" \
        '.end_time = $end_time | .duration_ms = $duration_ms | .status = $status' \
        > "$span_file"

    # Append to spans list
    local spans_file="$trace_dir/spans.json"
    if [ -f "$spans_file" ]; then
        local updated_span=$(cat "$span_file")
        local spans=$(cat "$spans_file")
        echo "$spans" | jq --argjson s "$updated_span" '. += [$s]' > "$spans_file"
    fi

    # Restore parent span as current
    _HIVE_CURRENT_SPAN_ID="$_HIVE_PARENT_SPAN_ID"
    _HIVE_PARENT_SPAN_ID=""

    export HIVE_CURRENT_SPAN_ID="$_HIVE_CURRENT_SPAN_ID"
    export HIVE_PARENT_SPAN_ID=""

    echo "$duration_ms"
}

# Add tags to a span
# Usage: span_add_tag <span_id> <key> <value> [run_id]
span_add_tag() {
    local span_id="$1"
    local key="$2"
    local value="$3"
    local run_id="${4:-}"

    local span_file="$HIVE_DIR/runs/$run_id/.trace/${span_id}.json"

    if [ -f "$span_file" ]; then
        local span=$(cat "$span_file")
        echo "$span" | jq --arg k "$key" --arg v "$value" '.tags[$k] = $v' > "$span_file"
    fi
}

# Add multiple tags at once (JSON object)
# Usage: span_add_tags <span_id> '{"key": "value"}' [run_id]
span_add_tags() {
    local span_id="$1"
    local tags_json="$2"
    local run_id="${3:-}"

    local span_file="$HIVE_DIR/runs/$run_id/.trace/${span_id}.json"

    if [ -f "$span_file" ]; then
        local span=$(cat "$span_file")
        echo "$span" | jq --argjson t "$tags_json" '.tags += $t' > "$span_file"
    fi
}

# Record files modified within a span
# Usage: span_record_file <span_id> <file_path> <action> [run_id]
span_record_file() {
    local span_id="$1"
    local file_path="$2"
    local action="${3:-modified}"
    local run_id="${4:-}"

    local span_file="$HIVE_DIR/runs/$run_id/.trace/${span_id}.json"

    if [ -f "$span_file" ]; then
        local file_entry=$(jq -n \
            --arg path "$file_path" \
            --arg action "$action" \
            --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{path: $path, action: $action, ts: $ts}'
        )
        local span=$(cat "$span_file")
        echo "$span" | jq --argjson f "$file_entry" '.files_modified = (.files_modified // []) + [$f]' > "$span_file"
    fi
}

# ============================================================================
# Trace Export
# ============================================================================

# Get all spans for a trace
# Usage: trace_get_spans [run_id]
trace_get_spans() {
    local run_id="${1:-}"
    local spans_file="$HIVE_DIR/runs/$run_id/.trace/spans.json"

    if [ -f "$spans_file" ]; then
        cat "$spans_file"
    else
        echo "[]"
    fi
}

# Export trace in a format suitable for visualization
# Usage: trace_export [run_id]
trace_export() {
    local run_id="${1:-}"
    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"

    if [ ! -d "$trace_dir" ]; then
        echo "{}"
        return 1
    fi

    local trace_id=$(cat "$trace_dir/trace_id" 2>/dev/null || echo "")
    local spans=$(cat "$trace_dir/spans.json" 2>/dev/null || echo "[]")

    jq -n \
        --arg trace_id "$trace_id" \
        --arg run_id "$run_id" \
        --argjson spans "$spans" \
        '{
            trace_id: $trace_id,
            run_id: $run_id,
            spans: $spans,
            span_count: ($spans | length),
            total_duration_ms: ([$spans[].duration_ms | select(. != null)] | add // 0)
        }'
}

# ============================================================================
# Utility Functions
# ============================================================================

# Check if tracing is initialized
trace_is_active() {
    [ -n "$_HIVE_TRACE_ID" ] || [ -n "$HIVE_TRACE_ID" ]
}

# Reset trace context (for testing)
trace_reset() {
    _HIVE_TRACE_ID=""
    _HIVE_CURRENT_SPAN_ID=""
    _HIVE_PARENT_SPAN_ID=""
    unset HIVE_TRACE_ID
    unset HIVE_CURRENT_SPAN_ID
    unset HIVE_PARENT_SPAN_ID
}
