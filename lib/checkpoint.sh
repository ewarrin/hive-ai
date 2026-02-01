#!/usr/bin/env bash
# Hive Checkpoint - Save and resume workflow state

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
CHECKPOINTS_DIR="$HIVE_DIR/checkpoints"

# ============================================================================
# Core Functions
# ============================================================================

# Save current state as a checkpoint
checkpoint_save() {
    local reason="${1:-manual}"
    
    mkdir -p "$CHECKPOINTS_DIR"
    
    local checkpoint_id=$(date +"%Y%m%d_%H%M%S")
    local checkpoint_file="$CHECKPOINTS_DIR/${checkpoint_id}.json"
    
    # Gather state from various sources
    local scratchpad=""
    if [ -f "$HIVE_DIR/scratchpad.json" ]; then
        scratchpad=$(cat "$HIVE_DIR/scratchpad.json")
    else
        scratchpad="{}"
    fi
    
    # Get Beads state if available
    local beads_state="[]"
    local epic_id=$(echo "$scratchpad" | jq -r '.epic_id // empty')
    if [ -n "$epic_id" ] && command -v bd &>/dev/null; then
        beads_state=$(bd list --json 2>/dev/null || echo "[]")
    fi
    
    # Get list of handoffs
    local handoffs="[]"
    if [ -d "$HIVE_DIR/handoffs" ]; then
        handoffs=$(ls -1 "$HIVE_DIR/handoffs"/*.json 2>/dev/null | jq -R -s 'split("\n") | map(select(. != ""))' || echo "[]")
    fi
    
    # Build checkpoint
    local checkpoint=$(jq -n \
        --arg id "$checkpoint_id" \
        --arg reason "$reason" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson scratchpad "$scratchpad" \
        --argjson beads "$beads_state" \
        --argjson handoffs "$handoffs" \
        '{
            checkpoint_id: $id,
            created_at: $ts,
            reason: $reason,
            scratchpad: $scratchpad,
            beads_state: $beads,
            handoff_files: $handoffs,
            version: "1.0"
        }'
    )
    
    echo "$checkpoint" > "$checkpoint_file"
    
    # Log the checkpoint
    if type log_checkpoint_saved &>/dev/null; then
        log_checkpoint_saved "$checkpoint_id" "$checkpoint_file"
    fi
    
    echo "$checkpoint_id"
}

# List available checkpoints
checkpoint_list() {
    if [ ! -d "$CHECKPOINTS_DIR" ]; then
        echo "[]"
        return
    fi
    
    local checkpoints="[]"
    for file in "$CHECKPOINTS_DIR"/*.json; do
        if [ -f "$file" ]; then
            local info=$(jq '{
                checkpoint_id: .checkpoint_id,
                created_at: .created_at,
                reason: .reason,
                phase: .scratchpad.current_phase,
                status: .scratchpad.status
            }' "$file")
            checkpoints=$(echo "$checkpoints" | jq --argjson c "$info" '. += [$c]')
        fi
    done
    
    echo "$checkpoints" | jq 'sort_by(.created_at) | reverse'
}

# Get the most recent checkpoint
checkpoint_latest() {
    local latest=$(ls -1t "$CHECKPOINTS_DIR"/*.json 2>/dev/null | head -1)
    if [ -n "$latest" ] && [ -f "$latest" ]; then
        basename "$latest" .json
    fi
}

# Get checkpoint details
checkpoint_show() {
    local checkpoint_id="$1"
    local checkpoint_file="$CHECKPOINTS_DIR/${checkpoint_id}.json"
    
    if [ -f "$checkpoint_file" ]; then
        cat "$checkpoint_file"
    else
        echo "Checkpoint not found: $checkpoint_id" >&2
        return 1
    fi
}

# Restore from a checkpoint
checkpoint_restore() {
    local checkpoint_id="$1"
    local checkpoint_file="$CHECKPOINTS_DIR/${checkpoint_id}.json"
    
    if [ ! -f "$checkpoint_file" ]; then
        echo "Checkpoint not found: $checkpoint_id" >&2
        return 1
    fi
    
    local checkpoint=$(cat "$checkpoint_file")
    
    # Restore scratchpad
    echo "$checkpoint" | jq '.scratchpad' > "$HIVE_DIR/scratchpad.json"
    
    # Log the restore
    if type log_checkpoint_restored &>/dev/null; then
        log_checkpoint_restored "$checkpoint_id"
    fi
    
    # Return key info for the orchestrator
    echo "$checkpoint" | jq '{
        checkpoint_id: .checkpoint_id,
        run_id: .scratchpad.run_id,
        epic_id: .scratchpad.epic_id,
        objective: .scratchpad.objective,
        current_phase: .scratchpad.current_phase,
        current_agent: .scratchpad.current_agent,
        status: .scratchpad.status
    }'
}

# Delete a checkpoint
checkpoint_delete() {
    local checkpoint_id="$1"
    local checkpoint_file="$CHECKPOINTS_DIR/${checkpoint_id}.json"
    
    if [ -f "$checkpoint_file" ]; then
        rm "$checkpoint_file"
        return 0
    else
        return 1
    fi
}

# Clean old checkpoints (keep last N)
checkpoint_cleanup() {
    local keep="${1:-10}"
    
    if [ ! -d "$CHECKPOINTS_DIR" ]; then
        return
    fi
    
    local count=$(ls -1 "$CHECKPOINTS_DIR"/*.json 2>/dev/null | wc -l)
    
    if [ "$count" -gt "$keep" ]; then
        local to_delete=$((count - keep))
        ls -1t "$CHECKPOINTS_DIR"/*.json | tail -n "$to_delete" | xargs rm -f
    fi
}

# ============================================================================
# Auto-checkpoint on failure
# ============================================================================

# Save checkpoint with failure context
checkpoint_on_failure() {
    local agent="$1"
    local error="$2"
    local attempt="$3"
    
    # Update scratchpad with failure info before checkpointing
    if [ -f "$HIVE_DIR/scratchpad.json" ]; then
        local current=$(cat "$HIVE_DIR/scratchpad.json")
        local failure_info=$(jq -n \
            --arg agent "$agent" \
            --arg error "$error" \
            --argjson attempt "$attempt" \
            --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{
                failed_at: $ts,
                failed_agent: $agent,
                failed_attempt: $attempt,
                error: $error
            }'
        )
        echo "$current" | jq --argjson f "$failure_info" '. + {last_failure: $f}' > "$HIVE_DIR/scratchpad.json"
    fi
    
    checkpoint_save "failure_${agent}_attempt_${attempt}"
}

# ============================================================================
# Resume helpers
# ============================================================================

# Determine what to do next based on checkpoint
checkpoint_get_resume_action() {
    local checkpoint_id="$1"
    local checkpoint=$(checkpoint_show "$checkpoint_id")
    
    local phase=$(echo "$checkpoint" | jq -r '.scratchpad.current_phase')
    local agent=$(echo "$checkpoint" | jq -r '.scratchpad.current_agent // empty')
    local status=$(echo "$checkpoint" | jq -r '.scratchpad.status')
    local attempt=$(echo "$checkpoint" | jq -r '.scratchpad.iteration.attempt // 0')
    local max_attempts=$(echo "$checkpoint" | jq -r '.scratchpad.iteration.max_attempts // 3')
    local last_failure=$(echo "$checkpoint" | jq -r '.scratchpad.last_failure // empty')
    
    # Build resume action
    jq -n \
        --arg phase "$phase" \
        --arg agent "$agent" \
        --arg status "$status" \
        --argjson attempt "$attempt" \
        --argjson max_attempts "$max_attempts" \
        --argjson last_failure "$last_failure" \
        '{
            phase: $phase,
            agent: $agent,
            status: $status,
            attempt: $attempt,
            max_attempts: $max_attempts,
            last_failure: $last_failure,
            action: (
                if $status == "complete" then "none"
                elif $attempt >= $max_attempts then "escalate"
                elif $agent != null and $agent != "" then "retry_agent"
                else "continue_phase"
                end
            )
        }'
}

# Get context for resuming (what an agent needs to know)
checkpoint_get_resume_context() {
    local checkpoint_id="$1"
    local checkpoint=$(checkpoint_show "$checkpoint_id")
    
    echo "$checkpoint" | jq '{
        objective: .scratchpad.objective,
        epic_id: .scratchpad.epic_id,
        current_phase: .scratchpad.current_phase,
        decisions: .scratchpad.decisions,
        blockers: [.scratchpad.blockers[] | select(.status == "open")],
        context: .scratchpad.context,
        pending_tasks: .scratchpad.pending_tasks,
        completed_tasks: .scratchpad.completed_tasks,
        last_failure: .scratchpad.last_failure
    }'
}
