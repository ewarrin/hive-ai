#!/usr/bin/env bash
# Hive Logger - Structured event logging to JSONL
#
# Enhanced with trace context support for observability:
# - run_id: Links events to workflow runs
# - trace_id: Unique identifier for end-to-end tracing
# - span_id: Current operation context
# - parent_span_id: Parent operation for nested spans
# - duration_ms: Timing information

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
EVENTS_FILE="$HIVE_DIR/events.jsonl"

# ============================================================================
# Trace Context Helpers
# ============================================================================

# Get current trace context from environment or scratchpad
_log_get_trace_context() {
    local run_id="${HIVE_RUN_ID:-}"
    local trace_id="${HIVE_TRACE_ID:-}"
    local span_id="${HIVE_CURRENT_SPAN_ID:-}"
    local parent_span_id="${HIVE_PARENT_SPAN_ID:-}"

    # Try to get run_id from scratchpad if not in env
    if [ -z "$run_id" ] && [ -f "$HIVE_DIR/scratchpad.json" ]; then
        # Validate file is valid JSON first
        if jq empty "$HIVE_DIR/scratchpad.json" 2>/dev/null; then
            run_id=$(jq -r '.run_id // empty' "$HIVE_DIR/scratchpad.json" 2>/dev/null) || run_id=""
        fi
    fi

    # Try to get trace_id from scratchpad if not in env
    if [ -z "$trace_id" ] && [ -f "$HIVE_DIR/scratchpad.json" ]; then
        if jq empty "$HIVE_DIR/scratchpad.json" 2>/dev/null; then
            trace_id=$(jq -r '.trace_id // empty' "$HIVE_DIR/scratchpad.json" 2>/dev/null) || trace_id=""
        fi
    fi

    # Build context JSON - use printf to avoid jq issues with empty values
    printf '{"run_id":%s,"trace_id":%s,"span_id":%s,"parent_span_id":%s}' \
        "$([ -n "$run_id" ] && echo "\"$run_id\"" || echo "null")" \
        "$([ -n "$trace_id" ] && echo "\"$trace_id\"" || echo "null")" \
        "$([ -n "$span_id" ] && echo "\"$span_id\"" || echo "null")" \
        "$([ -n "$parent_span_id" ] && echo "\"$parent_span_id\"" || echo "null")"
}

# ============================================================================
# Core Logging
# ============================================================================

# Log a structured event to the events file
# Usage: log_event "event_type" '{"key": "value"}' [duration_ms]
log_event() {
    local event_type="$1"
    local data="${2:-{\}}"
    local duration_ms="${3:-}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Ensure directory exists
    mkdir -p "$HIVE_DIR"

    # Validate data is valid JSON, default to empty object if not
    if ! echo "$data" | jq empty 2>/dev/null; then
        data="{}"
    fi

    # Get trace context (with fallback to empty object)
    local trace_ctx
    trace_ctx=$(_log_get_trace_context 2>/dev/null) || trace_ctx="{}"

    # Validate trace_ctx is valid JSON
    if ! echo "$trace_ctx" | jq empty 2>/dev/null; then
        trace_ctx="{}"
    fi

    # Build the event JSON with trace context
    local event
    if [ -n "$duration_ms" ] && [ "$duration_ms" -eq "$duration_ms" ] 2>/dev/null; then
        event=$(jq -cn \
            --arg ts "$timestamp" \
            --arg event "$event_type" \
            --argjson data "$data" \
            --argjson trace_ctx "$trace_ctx" \
            --argjson duration_ms "$duration_ms" \
            '{ts: $ts, event: $event} + $trace_ctx + {duration_ms: $duration_ms} + $data'
        ) 2>/dev/null
    else
        event=$(jq -cn \
            --arg ts "$timestamp" \
            --arg event "$event_type" \
            --argjson data "$data" \
            --argjson trace_ctx "$trace_ctx" \
            '{ts: $ts, event: $event} + $trace_ctx + $data'
        ) 2>/dev/null
    fi

    # Fallback if jq failed
    if [ -z "$event" ]; then
        event="{\"ts\":\"$timestamp\",\"event\":\"$event_type\"}"
    fi

    # Append to events file
    echo "$event" >> "$EVENTS_FILE"

    # Also output to stderr if HIVE_VERBOSE is set
    if [ "$HIVE_VERBOSE" == "1" ]; then
        echo "$event" | jq -c '.' >&2
    fi
}

# ============================================================================
# Convenience Functions
# ============================================================================

log_run_start() {
    local run_id="$1"
    local objective="$2"
    log_event "run_start" "$(jq -cn \
        --arg run_id "$run_id" \
        --arg objective "$objective" \
        '{run_id: $run_id, objective: $objective}'
    )"
}

log_run_complete() {
    local run_id="$1"
    local success="$2"
    local summary="${3:-}"
    log_event "run_complete" "$(jq -cn \
        --arg run_id "$run_id" \
        --argjson success "$success" \
        --arg summary "$summary" \
        '{run_id: $run_id, success: $success, summary: $summary}'
    )"
}

log_agent_start() {
    local agent="$1"
    local task_id="${2:-null}"
    log_event "agent_start" "$(jq -cn \
        --arg agent "$agent" \
        --arg task_id "$task_id" \
        '{agent: $agent, task_id: (if $task_id == "null" then null else $task_id end)}'
    )"
}

log_agent_complete() {
    local agent="$1"
    local success="$2"
    local contract_fulfilled="${3:-false}"
    local error="${4:-}"
    log_event "agent_complete" "$(jq -cn \
        --arg agent "$agent" \
        --argjson success "$success" \
        --argjson contract_fulfilled "$contract_fulfilled" \
        --arg error "$error" \
        '{agent: $agent, success: $success, contract_fulfilled: $contract_fulfilled} + (if $error != "" then {error: $error} else {} end)'
    )"
}

log_agent_retry() {
    local agent="$1"
    local attempt="$2"
    local max_attempts="$3"
    local reason="$4"
    log_event "agent_retry" "$(jq -cn \
        --arg agent "$agent" \
        --argjson attempt "$attempt" \
        --argjson max_attempts "$max_attempts" \
        --arg reason "$reason" \
        '{agent: $agent, attempt: $attempt, max_attempts: $max_attempts, reason: $reason}'
    )"
}

log_validation_pass() {
    local check="$1"
    local details="${2:-}"
    log_event "validation_pass" "$(jq -cn \
        --arg check "$check" \
        --arg details "$details" \
        '{check: $check} + (if $details != "" then {details: $details} else {} end)'
    )"
}

log_validation_fail() {
    local check="$1"
    local error="$2"
    local details="${3:-}"
    log_event "validation_fail" "$(jq -cn \
        --arg check "$check" \
        --arg error "$error" \
        --arg details "$details" \
        '{check: $check, error: $error} + (if $details != "" then {details: $details} else {} end)'
    )"
}

log_beads_create() {
    local task_id="$1"
    local title="$2"
    local task_type="${3:-task}"
    log_event "beads_create" "$(jq -cn \
        --arg task_id "$task_id" \
        --arg title "$title" \
        --arg type "$task_type" \
        '{task_id: $task_id, title: $title, type: $type}'
    )"
}

log_beads_update() {
    local task_id="$1"
    local status="$2"
    log_event "beads_update" "$(jq -cn \
        --arg task_id "$task_id" \
        --arg status "$status" \
        '{task_id: $task_id, status: $status}'
    )"
}

log_beads_close() {
    local task_id="$1"
    local reason="${2:-}"
    log_event "beads_close" "$(jq -cn \
        --arg task_id "$task_id" \
        --arg reason "$reason" \
        '{task_id: $task_id} + (if $reason != "" then {reason: $reason} else {} end)'
    )"
}

log_handoff_created() {
    local from_agent="$1"
    local to_agent="$2"
    local path="$3"
    log_event "handoff_created" "$(jq -cn \
        --arg from "$from_agent" \
        --arg to "$to_agent" \
        --arg path "$path" \
        '{from: $from, to: $to, path: $path}'
    )"
}

log_decision() {
    local agent="$1"
    local decision="$2"
    local rationale="${3:-}"
    log_event "decision" "$(jq -cn \
        --arg agent "$agent" \
        --arg decision "$decision" \
        --arg rationale "$rationale" \
        '{agent: $agent, decision: $decision} + (if $rationale != "" then {rationale: $rationale} else {} end)'
    )"
}

log_blocker() {
    local agent="$1"
    local blocker="$2"
    local task_id="${3:-}"
    log_event "blocker" "$(jq -cn \
        --arg agent "$agent" \
        --arg blocker "$blocker" \
        --arg task_id "$task_id" \
        '{agent: $agent, blocker: $blocker} + (if $task_id != "" then {task_id: $task_id} else {} end)'
    )"
}

log_checkpoint_saved() {
    local checkpoint_id="$1"
    local path="$2"
    log_event "checkpoint_saved" "$(jq -cn \
        --arg checkpoint_id "$checkpoint_id" \
        --arg path "$path" \
        '{checkpoint_id: $checkpoint_id, path: $path}'
    )"
}

log_checkpoint_restored() {
    local checkpoint_id="$1"
    log_event "checkpoint_restored" "$(jq -cn \
        --arg checkpoint_id "$checkpoint_id" \
        '{checkpoint_id: $checkpoint_id}'
    )"
}

log_file_modified() {
    local path="$1"
    local action="${2:-modified}"  # created, modified, deleted
    log_event "file_modified" "$(jq -cn \
        --arg path "$path" \
        --arg action "$action" \
        '{path: $path, action: $action}'
    )"
}

log_error() {
    local message="$1"
    local context="${2:-}"
    log_event "error" "$(jq -cn \
        --arg message "$message" \
        --arg context "$context" \
        '{message: $message} + (if $context != "" then {context: $context} else {} end)'
    )"
}

log_human_checkpoint() {
    local checkpoint_type="$1"
    local message="$2"
    local response="${3:-}"
    log_event "human_checkpoint" "$(jq -cn \
        --arg type "$checkpoint_type" \
        --arg message "$message" \
        --arg response "$response" \
        '{type: $type, message: $message} + (if $response != "" then {response: $response} else {} end)'
    )"
}

log_challenge() {
    local from_agent="$1"
    local to_agent="$2"
    local issue="$3"
    local suggestion="${4:-}"
    log_event "challenge" "$(jq -cn \
        --arg from "$from_agent" \
        --arg to "$to_agent" \
        --arg issue "$issue" \
        --arg suggestion "$suggestion" \
        '{from_agent: $from, to_agent: $to, issue: $issue} + (if $suggestion != "" then {suggestion: $suggestion} else {} end)'
    )"
}

log_challenge_resolved() {
    local from_agent="$1"
    local to_agent="$2"
    local resolution="${3:-resolved}"
    local attempts="${4:-1}"
    log_event "challenge_resolved" "$(jq -cn \
        --arg from "$from_agent" \
        --arg to "$to_agent" \
        --arg resolution "$resolution" \
        --argjson attempts "$attempts" \
        '{from_agent: $from, to_agent: $to, resolution: $resolution, attempts: $attempts}'
    )"
}

# ============================================================================
# Query Functions
# ============================================================================

# Get all events of a specific type
query_events_by_type() {
    local event_type="$1"
    cat "$EVENTS_FILE" 2>/dev/null | jq -c "select(.event == \"$event_type\")"
}

# Get all events for a specific agent
query_events_by_agent() {
    local agent="$1"
    cat "$EVENTS_FILE" 2>/dev/null | jq -c "select(.agent == \"$agent\")"
}

# Get events since a timestamp
query_events_since() {
    local since="$1"
    cat "$EVENTS_FILE" 2>/dev/null | jq -c "select(.ts >= \"$since\")"
}

# Get last N events
query_events_last() {
    local n="${1:-10}"
    tail -n "$n" "$EVENTS_FILE" 2>/dev/null
}

# Count events by type
query_event_counts() {
    cat "$EVENTS_FILE" 2>/dev/null | jq -s 'group_by(.event) | map({event: .[0].event, count: length})'
}

# ============================================================================
# Trace-Aware Query Functions
# ============================================================================

# Get all events for a specific run
query_events_by_run() {
    local run_id="$1"
    cat "$EVENTS_FILE" 2>/dev/null | jq -c "select(.run_id == \"$run_id\")"
}

# Get all events for a specific trace
query_events_by_trace() {
    local trace_id="$1"
    cat "$EVENTS_FILE" 2>/dev/null | jq -c "select(.trace_id == \"$trace_id\")"
}

# Get all events for a specific span
query_events_by_span() {
    local span_id="$1"
    cat "$EVENTS_FILE" 2>/dev/null | jq -c "select(.span_id == \"$span_id\")"
}
