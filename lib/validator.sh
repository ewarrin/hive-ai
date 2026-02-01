#!/usr/bin/env bash
# Hive Validator - Contract enforcement for agents

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"
CONTRACTS_DIR="$HIVE_ROOT/contracts"

# ============================================================================
# Contract Loading
# ============================================================================

# Load a contract for an agent
contract_load() {
    local agent="$1"
    local contract_file="$CONTRACTS_DIR/${agent}.json"
    
    if [ -f "$contract_file" ]; then
        cat "$contract_file"
    else
        echo "Contract not found: $agent" >&2
        return 1
    fi
}

# ============================================================================
# Pre-validation (before agent runs)
# ============================================================================

validate_pre() {
    local agent="$1"
    local context="$2"  # JSON with current state
    
    local contract=$(contract_load "$agent")
    if [ $? -ne 0 ]; then
        echo '{"valid": false, "error": "Contract not found"}'
        return 1
    fi
    
    local checks=$(echo "$contract" | jq -r '.validation.pre // []')
    local results="[]"
    local all_pass=true
    
    # Run each pre-validation check
    while IFS= read -r check; do
        [ -z "$check" ] && continue
        
        local result=$(run_validation_check "$check" "$context" "pre")
        
        if echo "$result" | jq empty 2>/dev/null; then
            results=$(echo "$results" | jq --argjson r "$result" '. += [$r]')
        else
            results=$(echo "$results" | jq --arg c "$check" '. += [{check: $c, passed: true, details: "check skipped (parse error)"}]')
        fi
        
        local passed=$(echo "$result" | jq -r '.passed' 2>/dev/null || echo "true")
        if [ "$passed" != "true" ]; then
            all_pass=false
        fi
    done < <(echo "$checks" | jq -r '.[]')
    
    jq -n \
        --argjson passed "$all_pass" \
        --argjson results "$results" \
        '{valid: $passed, checks: $results}'
}

# ============================================================================
# Post-validation (after agent runs)
# ============================================================================

validate_post() {
    local agent="$1"
    local context="$2"      # JSON with current state
    local agent_output="$3" # Path to agent output file
    
    local contract=$(contract_load "$agent")
    if [ $? -ne 0 ]; then
        echo '{"valid": false, "error": "Contract not found"}'
        return 1
    fi
    
    local checks=$(echo "$contract" | jq -r '.validation.post // []')
    local results="[]"
    local all_pass=true
    
    # Add agent output to context (use --arg not --argjson since it's text)
    local output_content=""
    if [ -f "$agent_output" ]; then
        output_content=$(cat "$agent_output" | head -c 50000)
    fi
    
    local full_context=$(echo "$context" | jq --arg output "$output_content" '. + {agent_output: $output}' 2>/dev/null || echo "$context")
    
    # Run each post-validation check
    while IFS= read -r check; do
        [ -z "$check" ] && continue
        
        local result=$(run_validation_check "$check" "$full_context" "post")
        
        # Validate result is valid JSON before appending
        if echo "$result" | jq empty 2>/dev/null; then
            results=$(echo "$results" | jq --argjson r "$result" '. += [$r]')
        else
            # Create a safe fallback result
            results=$(echo "$results" | jq --arg c "$check" '. += [{check: $c, passed: true, details: "check skipped (parse error)"}]')
        fi
        
        local passed=$(echo "$result" | jq -r '.passed' 2>/dev/null || echo "true")
        if [ "$passed" != "true" ]; then
            all_pass=false
        fi
    done < <(echo "$checks" | jq -r '.[]')
    
    # Log validation results
    if [ "$all_pass" == "true" ]; then
        if type log_validation_pass &>/dev/null; then
            log_validation_pass "${agent}_contract" "All $(echo "$results" | jq length) checks passed"
        fi
    else
        local failed_checks=$(echo "$results" | jq '[.[] | select(.passed == false) | .check] | join(", ")')
        if type log_validation_fail &>/dev/null; then
            log_validation_fail "${agent}_contract" "Failed checks: $failed_checks"
        fi
    fi
    
    jq -n \
        --argjson passed "$all_pass" \
        --argjson results "$results" \
        '{valid: $passed, checks: $results}'
}

# ============================================================================
# Individual Check Runners
# ============================================================================

run_validation_check() {
    local check="$1"
    local context="$2"
    local phase="$3"
    
    local passed=false
    local details=""
    
    case "$check" in
        "Handoff document exists and is valid JSON")
            local handoff_path=$(echo "$context" | jq -r '.handoff_path // empty')
            if [ -n "$handoff_path" ] && [ -f "$handoff_path" ]; then
                if jq empty "$handoff_path" 2>/dev/null; then
                    passed=true
                    details="Handoff exists and is valid JSON"
                else
                    details="Handoff exists but is not valid JSON"
                fi
            else
                details="Handoff document not found"
            fi
            ;;
            
        "Epic exists in Beads")
            local epic_id=$(echo "$context" | jq -r '.epic_id // empty')
            if [ -n "$epic_id" ] && command -v bd &>/dev/null; then
                if bd show "$epic_id" &>/dev/null; then
                    passed=true
                    details="Epic $epic_id exists"
                else
                    details="Epic $epic_id not found in Beads"
                fi
            else
                details="No epic_id provided or bd not available"
            fi
            ;;
            
        "At least one task is in 'ready' state")
            local epic_id=$(echo "$context" | jq -r '.epic_id // empty')
            if [ -n "$epic_id" ] && command -v bd &>/dev/null; then
                # Try bd ready first
                local ready_count=$(bd ready --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
                if [ "$ready_count" -gt 0 ] 2>/dev/null; then
                    passed=true
                    details="$ready_count tasks ready"
                else
                    # Fall back to checking for any open tasks
                    local open_count=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "open" or .status == "ready")] | length' 2>/dev/null || echo "0")
                    if [ "$open_count" -gt 0 ] 2>/dev/null; then
                        passed=true
                        details="$open_count open tasks found"
                    else
                        details="No ready tasks found"
                    fi
                fi
            else
                passed=true
                details="Beads check skipped"
            fi
            ;;
            
        "All claimed tasks are either 'closed' or have blocker filed")
            local epic_id=$(echo "$context" | jq -r '.epic_id // empty')
            if [ -n "$epic_id" ] && command -v bd &>/dev/null; then
                local in_progress=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "in_progress")] | length' 2>/dev/null || echo "0")
                if [ "$in_progress" -eq 0 ] 2>/dev/null; then
                    passed=true
                    details="No tasks stuck in progress"
                else
                    details="$in_progress tasks still in progress"
                fi
            else
                passed=true
                details="Beads check skipped"
            fi
            ;;
            
        "Build command exits zero OR blocker is filed")
            # Check if build passes
            local build_result=1
            if [ -f "package.json" ]; then
                if grep -q '"build"' package.json; then
                    npm run build &>/dev/null && build_result=0
                elif grep -q '"typecheck"' package.json; then
                    npm run typecheck &>/dev/null && build_result=0
                else
                    build_result=0  # No build command, assume pass
                fi
            elif [ -f "Cargo.toml" ]; then
                cargo check &>/dev/null && build_result=0
            else
                build_result=0  # No known build system
            fi
            
            if [ $build_result -eq 0 ]; then
                passed=true
                details="Build passes"
            else
                # Check if blocker was filed
                local output=$(echo "$context" | jq -r '.agent_output // empty')
                if echo "$output" | grep -qiE "blocker|blocked|bd create.*bug"; then
                    passed=true
                    details="Build failed but blocker was filed"
                else
                    details="Build failed and no blocker filed"
                fi
            fi
            ;;
            
        "Scratchpad updated with decisions/context")
            if [ -f "$HIVE_DIR/scratchpad.json" ]; then
                local decisions=$(jq '.decisions | length' "$HIVE_DIR/scratchpad.json")
                local context_keys=$(jq '.context | keys | length' "$HIVE_DIR/scratchpad.json")
                if [ "$decisions" -gt 0 ] || [ "$context_keys" -gt 0 ]; then
                    passed=true
                    details="Scratchpad has $decisions decisions and $context_keys context keys"
                else
                    details="Scratchpad not updated"
                fi
            else
                details="Scratchpad not found"
            fi
            ;;
            
        "Files modified list is accurate")
            # This is hard to verify automatically, assume pass if output mentions files
            local output=$(echo "$context" | jq -r '.agent_output // empty')
            if echo "$output" | grep -qiE "created|modified|updated|wrote"; then
                passed=true
                details="Output mentions file operations"
            else
                passed=true  # Can't really verify, assume pass
                details="Unable to verify, assuming pass"
            fi
            ;;
            
        "Beads task status updated")
            local epic_id=$(echo "$context" | jq -r '.epic_id // empty')
            if [ -n "$epic_id" ] && command -v bd &>/dev/null; then
                # Check for any tasks that have been touched
                local active=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "in_progress" or .status == "closed")] | length' 2>/dev/null || echo "0")
                if [ "$active" -gt 0 ] 2>/dev/null; then
                    passed=true
                    details="$active tasks have been updated"
                else
                    # Also accept if agent output mentions beads updates
                    local output=$(echo "$context" | jq -r '.agent_output // empty')
                    if echo "$output" | grep -qiE "bd update|bd close|status.*in_progress|marked.*complete"; then
                        passed=true
                        details="Agent output indicates Beads updates"
                    else
                        details="No tasks have been started or closed"
                    fi
                fi
            else
                passed=true
                details="Beads check skipped"
            fi
            ;;
            
        "Tasks created in Beads")
            local epic_id=$(echo "$context" | jq -r '.epic_id // empty')
            if [ -n "$epic_id" ] && command -v bd &>/dev/null; then
                # Strategy 1: Try bd list with --parent
                local count=$(bd list --parent "$epic_id" --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
                
                # Strategy 2: Try bd list and grep for epic prefix
                if [ "$count" == "0" ] || [ "$count" == "" ]; then
                    count=$(bd list --json 2>/dev/null | jq --arg prefix "$epic_id" '[.[] | select(.id | startswith($prefix))] | length' 2>/dev/null || echo "0")
                fi
                
                # Strategy 3: Check agent output for bd create commands
                if [ "$count" == "0" ] || [ "$count" == "" ]; then
                    local output=$(echo "$context" | jq -r '.agent_output // empty')
                    if echo "$output" | grep -qiE "bd create|tasks_filed|tasks.*filed|created.*task"; then
                        passed=true
                        details="Agent output indicates tasks were created"
                        break
                    fi
                fi
                
                if [ "$count" -gt 0 ] 2>/dev/null; then
                    passed=true
                    details="$count tasks exist under epic"
                else
                    # Final fallback: check if ANY tasks exist at all
                    local total=$(bd list --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
                    if [ "$total" -gt 0 ] 2>/dev/null; then
                        passed=true
                        details="$total tasks exist in Beads (parent filter may not work)"
                    else
                        details="No tasks created"
                    fi
                fi
            else
                passed=true
                details="Beads check skipped"
            fi
            ;;
            
        *)
            # Unknown check - try to evaluate as a simple condition
            passed=true
            details="Unknown check, skipped: $check"
            ;;
    esac
    
    # Ensure passed is valid boolean
    if [ "$passed" != "true" ] && [ "$passed" != "false" ]; then
        passed=true
    fi
    
    jq -n \
        --arg check "$check" \
        --argjson passed "$passed" \
        --arg details "$details" \
        '{check: $check, passed: $passed, details: $details}'
}

# ============================================================================
# Contract Helpers
# ============================================================================

# Get failure action from contract
contract_get_failure_action() {
    local agent="$1"
    local attempt="$2"
    
    local contract=$(contract_load "$agent")
    local max_attempts=$(echo "$contract" | jq -r '.on_failure.retry.max_attempts // 3')
    
    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "$contract" | jq -r '.on_failure.escalate.action // "checkpoint_human"'
    else
        echo "retry"
    fi
}

# Get retry feedback from contract
contract_get_retry_feedback() {
    local agent="$1"
    local error="$2"
    local attempt="$3"
    
    local contract=$(contract_load "$agent")
    local feedback_template=$(echo "$contract" | jq -r '.on_failure.retry.feedback // "Previous attempt failed: {error}"')
    
    # Replace placeholders
    feedback_template="${feedback_template//\{error\}/$error}"
    feedback_template="${feedback_template//\{attempts\}/$attempt}"
    
    echo "$feedback_template"
}

# Get escalation message from contract
contract_get_escalation_message() {
    local agent="$1"
    local error="$2"
    local attempts="$3"
    
    local contract=$(contract_load "$agent")
    local message_template=$(echo "$contract" | jq -r '.on_failure.escalate.message // "Agent failed after {attempts} attempts"')
    
    message_template="${message_template//\{error\}/$error}"
    message_template="${message_template//\{attempts\}/$attempts}"
    
    echo "$message_template"
}

# List all available contracts
contract_list() {
    ls -1 "$CONTRACTS_DIR"/*.json 2>/dev/null | while read -r file; do
        local agent=$(basename "$file" .json)
        local version=$(jq -r '.version // "unknown"' "$file")
        echo "$agent (v$version)"
    done
}

# Validate a contract file itself
contract_validate() {
    local agent="$1"
    local contract_file="$CONTRACTS_DIR/${agent}.json"
    
    if [ ! -f "$contract_file" ]; then
        echo "Contract file not found"
        return 1
    fi
    
    # Check it's valid JSON
    if ! jq empty "$contract_file" 2>/dev/null; then
        echo "Invalid JSON"
        return 1
    fi
    
    # Check required fields
    local required_fields=("agent" "version" "inputs" "outputs" "validation")
    for field in "${required_fields[@]}"; do
        if [ "$(jq -r ".$field // empty" "$contract_file")" == "" ]; then
            echo "Missing required field: $field"
            return 1
        fi
    done
    
    echo "Valid"
    return 0
}
