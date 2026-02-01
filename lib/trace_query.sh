#!/usr/bin/env bash
# Hive Trace Query - Query and analyze trace data
#
# Provides functions to:
# - Query events by trace_id, span_id, run_id
# - Get decision chains with timing
# - Track file lineage (which spans modified which files)
# - Visualize trace timelines

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
EVENTS_FILE="$HIVE_DIR/events.jsonl"

# ============================================================================
# Event Queries
# ============================================================================

# Get all events for a specific run
# Usage: trace_query_by_run <run_id>
trace_query_by_run() {
    local run_id="$1"

    if [ ! -f "$EVENTS_FILE" ]; then
        echo "[]"
        return 0
    fi

    cat "$EVENTS_FILE" | jq -sc --arg run_id "$run_id" \
        '[.[] | select(.run_id == $run_id)]'
}

# Get all events for a specific trace
# Usage: trace_query_by_trace <trace_id>
trace_query_by_trace() {
    local trace_id="$1"

    if [ ! -f "$EVENTS_FILE" ]; then
        echo "[]"
        return 0
    fi

    cat "$EVENTS_FILE" | jq -sc --arg trace_id "$trace_id" \
        '[.[] | select(.trace_id == $trace_id)]'
}

# Get all events for a specific span
# Usage: trace_query_by_span <span_id>
trace_query_by_span() {
    local span_id="$1"

    if [ ! -f "$EVENTS_FILE" ]; then
        echo "[]"
        return 0
    fi

    cat "$EVENTS_FILE" | jq -sc --arg span_id "$span_id" \
        '[.[] | select(.span_id == $span_id)]'
}

# Get events with both trace context and filtering
# Usage: trace_query_events [--run_id X] [--trace_id X] [--event_type X] [--agent X]
trace_query_events() {
    local run_id=""
    local trace_id=""
    local event_type=""
    local agent=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --run_id) run_id="$2"; shift 2 ;;
            --trace_id) trace_id="$2"; shift 2 ;;
            --event_type) event_type="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ ! -f "$EVENTS_FILE" ]; then
        echo "[]"
        return 0
    fi

    local filter="true"
    [ -n "$run_id" ] && filter="$filter and .run_id == \"$run_id\""
    [ -n "$trace_id" ] && filter="$filter and .trace_id == \"$trace_id\""
    [ -n "$event_type" ] && filter="$filter and .event == \"$event_type\""
    [ -n "$agent" ] && filter="$filter and .agent == \"$agent\""

    cat "$EVENTS_FILE" | jq -sc "[.[] | select($filter)]"
}

# ============================================================================
# Decision Chain Queries
# ============================================================================

# Get all decisions for a trace, ordered by time
# Usage: trace_get_decisions <run_id>
trace_get_decisions() {
    local run_id="$1"

    if [ ! -f "$EVENTS_FILE" ]; then
        echo "[]"
        return 0
    fi

    cat "$EVENTS_FILE" | jq -sc --arg run_id "$run_id" \
        '[.[] | select(.run_id == $run_id and .event == "decision")] | sort_by(.ts)'
}

# Get the decision chain with timing and agent attribution
# Usage: trace_get_decision_chain <run_id>
trace_get_decision_chain() {
    local run_id="$1"
    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"

    # Get decisions from events
    local decisions=$(trace_get_decisions "$run_id")

    # Get spans for timing context
    local spans="[]"
    if [ -f "$trace_dir/spans.json" ]; then
        spans=$(cat "$trace_dir/spans.json")
    fi

    # Combine into decision chain
    jq -n \
        --arg run_id "$run_id" \
        --argjson decisions "$decisions" \
        --argjson spans "$spans" \
        '{
            run_id: $run_id,
            decisions: $decisions,
            timeline: [
                $decisions[] | {
                    ts: .ts,
                    agent: .agent,
                    decision: .decision,
                    rationale: .rationale,
                    span_id: .span_id
                }
            ],
            by_agent: ($decisions | group_by(.agent) | map({
                agent: .[0].agent,
                count: length,
                decisions: [.[].decision]
            }))
        }'
}

# ============================================================================
# File Lineage Queries
# ============================================================================

# Get all file modifications for a run
# Usage: trace_get_file_modifications <run_id>
trace_get_file_modifications() {
    local run_id="$1"

    if [ ! -f "$EVENTS_FILE" ]; then
        echo "[]"
        return 0
    fi

    cat "$EVENTS_FILE" | jq -sc --arg run_id "$run_id" \
        '[.[] | select(.run_id == $run_id and .event == "file_modified")]'
}

# Get the lineage of a specific file (which spans/agents touched it)
# Usage: trace_get_file_lineage <run_id> <file_path>
trace_get_file_lineage() {
    local run_id="$1"
    local file_path="$2"

    local modifications=$(trace_get_file_modifications "$run_id")

    echo "$modifications" | jq --arg path "$file_path" \
        '[.[] | select(.path == $path)] | {
            path: $path,
            modifications: .,
            agents: [.[].agent] | unique,
            spans: [.[].span_id] | unique,
            first_modified: (.[0].ts // null),
            last_modified: (.[-1].ts // null),
            total_changes: length
        }'
}

# Get files modified by a specific agent
# Usage: trace_get_files_by_agent <run_id> <agent>
trace_get_files_by_agent() {
    local run_id="$1"
    local agent="$2"

    local modifications=$(trace_get_file_modifications "$run_id")

    echo "$modifications" | jq --arg agent "$agent" \
        '[.[] | select(.agent == $agent)] | {
            agent: $agent,
            files: [.[].path] | unique,
            modifications: .
        }'
}

# ============================================================================
# Span Analysis
# ============================================================================

# Get span hierarchy (parent-child relationships)
# Usage: trace_get_span_tree <run_id>
trace_get_span_tree() {
    local run_id="$1"
    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"

    if [ ! -f "$trace_dir/spans.json" ]; then
        echo "{}"
        return 0
    fi

    local spans=$(cat "$trace_dir/spans.json")

    # Build tree structure
    echo "$spans" | jq '
        def build_tree:
            . as $spans |
            [.[] | select(.parent_span_id == null)] as $roots |
            $roots | map(. + {
                children: [$spans[] | select(.parent_span_id == .span_id)]
            });

        {
            spans: .,
            roots: [.[] | select(.parent_span_id == null) | .span_id],
            total_spans: length,
            by_operation: (group_by(.operation) | map({
                operation: .[0].operation,
                count: length,
                total_duration_ms: ([.[].duration_ms | select(. != null)] | add // 0)
            }))
        }
    '
}

# Get timing breakdown by phase/agent
# Usage: trace_get_timing_breakdown <run_id>
trace_get_timing_breakdown() {
    local run_id="$1"
    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"

    if [ ! -f "$trace_dir/spans.json" ]; then
        echo "{}"
        return 0
    fi

    cat "$trace_dir/spans.json" | jq '
        {
            by_operation: (group_by(.operation) | map({
                operation: .[0].operation,
                count: length,
                total_ms: ([.[].duration_ms | select(. != null)] | add // 0),
                avg_ms: (([.[].duration_ms | select(. != null)] | add // 0) / ([.[].duration_ms | select(. != null)] | length // 1)),
                min_ms: ([.[].duration_ms | select(. != null)] | min // 0),
                max_ms: ([.[].duration_ms | select(. != null)] | max // 0)
            }) | sort_by(-.total_ms)),
            total_duration_ms: ([.[].duration_ms | select(. != null)] | add // 0),
            span_count: length
        }
    '
}

# ============================================================================
# Visualization Helpers
# ============================================================================

# Print a simple ASCII timeline of spans
# Usage: trace_print_timeline <run_id>
trace_print_timeline() {
    local run_id="$1"
    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"

    if [ ! -f "$trace_dir/spans.json" ]; then
        echo "No trace data found for run: $run_id"
        return 1
    fi

    echo ""
    echo "Trace Timeline: $run_id"
    echo "════════════════════════════════════════════════════════════"

    cat "$trace_dir/spans.json" | jq -r '
        sort_by(.start_time) |
        .[] |
        "\(.start_time | split("T")[1] | split("Z")[0]) │ \(.operation | .[0:20] | . + (" " * (20 - length))) │ \(.duration_ms // 0)ms │ \(.status)"
    '

    echo "════════════════════════════════════════════════════════════"

    local total=$(cat "$trace_dir/spans.json" | jq '[.[].duration_ms | select(. != null)] | add // 0')
    echo "Total Duration: ${total}ms"
}

# Get trace summary for quick overview
# Usage: trace_summary <run_id>
trace_summary() {
    local run_id="$1"
    local trace_dir="$HIVE_DIR/runs/$run_id/.trace"

    local trace_id=""
    if [ -f "$trace_dir/trace_id" ]; then
        trace_id=$(cat "$trace_dir/trace_id")
    fi

    local spans="[]"
    if [ -f "$trace_dir/spans.json" ]; then
        spans=$(cat "$trace_dir/spans.json")
    fi

    local events=$(trace_query_by_run "$run_id")
    local decisions=$(trace_get_decisions "$run_id")
    local files=$(trace_get_file_modifications "$run_id")

    jq -n \
        --arg run_id "$run_id" \
        --arg trace_id "$trace_id" \
        --argjson spans "$spans" \
        --argjson events "$events" \
        --argjson decisions "$decisions" \
        --argjson files "$files" \
        '{
            run_id: $run_id,
            trace_id: $trace_id,
            span_count: ($spans | length),
            event_count: ($events | length),
            decision_count: ($decisions | length),
            file_count: ($files | [.[].path] | unique | length),
            total_duration_ms: ([$spans[].duration_ms | select(. != null)] | add // 0),
            agents: ([$spans[].operation] | unique),
            files_modified: ([$files[].path] | unique)
        }'
}
