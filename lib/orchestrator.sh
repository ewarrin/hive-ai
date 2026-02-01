#!/usr/bin/env bash
# Hive Orchestrator v2 - Main workflow coordination
#
# v2 features:
# - Workflow templates (feature, bugfix, refactor, test, review, quick)
# - Agent self-evaluation (HIVE_REPORT blocks)
# - Project memory across runs
# - Diff-aware review/testing
# - Post-mortem reports
# - Agent timing/stats

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logger.sh"
source "$SCRIPT_DIR/scratchpad.sh"
source "$SCRIPT_DIR/checkpoint.sh"
source "$SCRIPT_DIR/handoff.sh"
source "$SCRIPT_DIR/validator.sh"
source "$SCRIPT_DIR/router.sh"
source "$SCRIPT_DIR/selfeval.sh"
source "$SCRIPT_DIR/workflow.sh"
source "$SCRIPT_DIR/memory.sh"
source "$SCRIPT_DIR/diff.sh"
source "$SCRIPT_DIR/postmortem.sh"
source "$SCRIPT_DIR/index.sh"
source "$SCRIPT_DIR/progress.sh"
source "$SCRIPT_DIR/subagent.sh"
source "$SCRIPT_DIR/cost.sh"
source "$SCRIPT_DIR/findings.sh"
source "$SCRIPT_DIR/parallel.sh"
source "$SCRIPT_DIR/git.sh"
source "$SCRIPT_DIR/agent_memory.sh"
source "$SCRIPT_DIR/smart_select.sh"
source "$SCRIPT_DIR/claude_updater.sh"

# ============================================================================
# Colors
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================================
# Output Helpers
# ============================================================================

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_phase() {
    echo ""
    echo -e "${BOLD}▶ $1${NC}"
    echo -e "${DIM}──────────────────────────────────────${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

# ============================================================================
# Beads Integration
# ============================================================================

beads_create_epic() {
    local title="$1"
    local description="$2"
    
    if ! command -v bd &>/dev/null; then
        print_error "Beads (bd) not found. Please install it first."
        return 1
    fi
    
    local output=$(bd create "$title" -t epic -p 1 --description "$description" 2>&1)
    
    local epic_id=""
    if echo "$output" | jq -e '.id' &>/dev/null 2>&1; then
        epic_id=$(echo "$output" | jq -r '.id')
    else
        epic_id=$(echo "$output" | grep -oE '\b[a-zA-Z][a-zA-Z0-9_]*-[a-z0-9]{2,6}\b' | head -1)
    fi
    
    if [ -n "$epic_id" ] && [[ "$epic_id" != --* ]]; then
        log_beads_create "$epic_id" "$title" "epic"
        echo "$epic_id"
    else
        print_error "Failed to create epic"
        return 1
    fi
}

beads_get_ready_tasks() {
    local epic_id="$1"
    bd ready --json 2>/dev/null || echo "[]"
}

# ============================================================================
# Agent Execution
# ============================================================================

# Build role-appropriate context for an agent
# Different agents need different context to work effectively
curate_context_for_agent() {
    local agent="$1"
    local epic_id="$2"
    local run_id="$3"
    local handoff_id="$4"
    local objective="$5"

    local context=""

    # Common: user-provided context files (always included)
    if [ -n "${HIVE_CONTEXT_FILES:-}" ]; then
        for ctx_file in $HIVE_CONTEXT_FILES; do
            if [ -f "$ctx_file" ]; then
                context="$context

## Reference: $(basename "$ctx_file")
$(cat "$ctx_file")"
            fi
        done
    fi

    case "$agent" in
        architect)
            # Maximum context for planning - needs full picture
            local mem_context=$(memory_context_for_agent)
            local idx_context=$(index_context_for_agent)
            [ -n "$mem_context" ] && context="$context

$mem_context"
            [ -n "$idx_context" ] && context="$context

$idx_context"
            [ -f "CLAUDE.md" ] && context="$context

## Project Guidelines (CLAUDE.md)
$(cat CLAUDE.md)"
            ;;

        implementer)
            # Architect's plan, relevant files, test patterns, mistake history
            local agent_ctx=$(agent_memory_context "$agent" 2>/dev/null)
            [ -n "$agent_ctx" ] && context="$context
$agent_ctx"
            # Index for file structure awareness
            local idx_context=$(index_context_for_agent)
            [ -n "$idx_context" ] && context="$context

$idx_context"
            # Memory for conventions and gotchas
            local mem_context=$(memory_context_for_agent)
            [ -n "$mem_context" ] && context="$context

$mem_context"
            ;;

        tester|e2e-tester|component-tester)
            # Diff only, implementer notes, test framework info
            local diff_ctx=$(diff_context_for_agent "$run_id" "current")
            [ -n "$diff_ctx" ] && context="$context

$diff_ctx"
            local test_cmd=$(memory_get_test_command)
            [ -n "$test_cmd" ] && context="$context

## Test Command
\`$test_cmd\`"
            # Agent-specific memory for common test issues
            local agent_ctx=$(agent_memory_context "$agent" 2>/dev/null)
            [ -n "$agent_ctx" ] && context="$context
$agent_ctx"
            ;;

        reviewer|security)
            # Objective, diff, architect plan - focused on what changed
            context="$context

## Original Objective
$objective"
            local diff_ctx=$(diff_context_for_agent "$run_id" "current")
            [ -n "$diff_ctx" ] && context="$context

$diff_ctx"
            # Agent-specific memory for common issues found
            local agent_ctx=$(agent_memory_context "$agent" 2>/dev/null)
            [ -n "$agent_ctx" ] && context="$context
$agent_ctx"
            ;;

        documenter)
            # CLAUDE.md style reference, minimal codebase context
            [ -f "CLAUDE.md" ] && context="$context

## Style Reference (CLAUDE.md)
$(cat CLAUDE.md)"
            local idx_context=$(index_context_for_agent)
            [ -n "$idx_context" ] && context="$context

$idx_context"
            ;;

        debugger)
            # Focus on error context and relevant code
            local mem_context=$(memory_context_for_agent)
            local idx_context=$(index_context_for_agent)
            [ -n "$mem_context" ] && context="$context

$mem_context"
            [ -n "$idx_context" ] && context="$context

$idx_context"
            # Agent-specific memory for common debugging patterns
            local agent_ctx=$(agent_memory_context "$agent" 2>/dev/null)
            [ -n "$agent_ctx" ] && context="$context
$agent_ctx"
            ;;

        *)
            # Default: project memory + index (full context)
            local mem_context=$(memory_context_for_agent)
            local idx_context=$(index_context_for_agent)
            [ -n "$mem_context" ] && context="$context

$mem_context"
            [ -n "$idx_context" ] && context="$context

$idx_context"
            [ -f "CLAUDE.md" ] && context="$context

## Project Guidelines (CLAUDE.md)
$(cat CLAUDE.md)"
            ;;
    esac

    # Always add challenge history for this agent (all agents)
    local challenge_ctx=$(memory_challenge_context_for "$agent" 2>/dev/null)
    [ -n "$challenge_ctx" ] && context="$context
$challenge_ctx"

    # Always add agent-specific memory warnings
    local agent_warnings=$(agent_memory_get_warnings "$agent" 2>/dev/null)
    [ -n "$agent_warnings" ] && context="$context

## Warnings from Previous Runs
$agent_warnings"

    echo "$context"
}

# Resolve agent prompt file with framework-aware fallback chain
# Priority: 1. Project-local specialized (e.g., .hive/agents/implementer-nuxt.md)
#           2. Project-local generic
#           3. Global specialized (e.g., ~/.hive/global/agents/implementer-nuxt.md)
#           4. Global generic
#           5. Bundled fallback
resolve_agent_prompt() {
    local agent="$1"
    local framework=$(memory_read 2>/dev/null | jq -r '.project.framework // ""' 2>/dev/null)

    # 1. Project-local specialized (e.g., .hive/agents/implementer-nuxt.md)
    if [ -n "$framework" ] && [ -f "$HIVE_DIR/agents/${agent}-${framework}.md" ]; then
        echo "$HIVE_DIR/agents/${agent}-${framework}.md"
        return
    fi

    # 2. Project-local generic
    if [ -f "$HIVE_DIR/agents/${agent}.md" ]; then
        echo "$HIVE_DIR/agents/${agent}.md"
        return
    fi

    # 3. Global specialized (e.g., ~/.hive/global/agents/implementer-nuxt.md)
    if [ -n "$framework" ] && [ -f "$HIVE_ROOT/global/agents/${agent}-${framework}.md" ]; then
        echo "$HIVE_ROOT/global/agents/${agent}-${framework}.md"
        return
    fi

    # 4. Global generic
    if [ -f "$HIVE_ROOT/global/agents/${agent}.md" ]; then
        echo "$HIVE_ROOT/global/agents/${agent}.md"
        return
    fi

    # 5. Bundled fallback
    echo "$HIVE_ROOT/agents/${agent}.md"
}

run_agent() {
    local agent="$1"
    local task="$2"
    local handoff_id="$3"
    local output_file="$4"

    # Resolve agent prompt with framework-aware fallback
    local agent_prompt=$(resolve_agent_prompt "$agent")
    
    if [ ! -f "$agent_prompt" ]; then
        print_error "Agent not found: $agent"
        log_error "Agent not found" "$agent"
        return 1
    fi
    
    local system_prompt=$(cat "$agent_prompt")
    local epic_id=$(scratchpad_get "epic_id")
    local objective=$(scratchpad_get "objective")
    local run_id=$(scratchpad_get "run_id")
    
    system_prompt="${system_prompt//\{\{EPIC_ID\}\}/$epic_id}"

    # Build context using role-appropriate curation
    local context=$(curate_context_for_agent "$agent" "$epic_id" "$run_id" "$handoff_id" "$objective")

    # Run sub-agents for agents that have them (currently: architect)
    if agent_has_subagents "$agent"; then
        local project_mem=$(memory_read 2>/dev/null || echo "{}")
        local idx_context=$(index_context_for_agent)
        local subagent_context=$(run_subagents_for_context "$agent" "$objective" "$idx_context" "$project_mem" "$epic_id")
        if [ -n "$subagent_context" ]; then
            context="$context

$subagent_context"
        fi
    fi

    # Add scratchpad summary (always needed)
    local sp_summary=$(scratchpad_summary)
    context="$context

## Current State (Hive Scratchpad)
\`\`\`json
$sp_summary
\`\`\`"

    # Add handoff if provided
    if [ -n "$handoff_id" ]; then
        local handoff_md=$(handoff_to_markdown "$handoff_id")
        if [ -n "$handoff_md" ]; then
            context="$context

$handoff_md"
            handoff_mark_received "$handoff_id"
        fi
    fi

    # Add Beads context
    local ready_tasks=$(beads_get_ready_tasks "$epic_id")
    if [ "$ready_tasks" != "[]" ]; then
        context="$context

## Ready Tasks (Beads)
\`\`\`json
$ready_tasks
\`\`\`"
    fi
    
    # Build full prompt with self-eval instructions
    local full_prompt="$system_prompt
$context

---

CURRENT EPIC: $epic_id
OBJECTIVE: $objective

TASK:
$task

---

Remember:
1. Update Beads task status (bd update <id> --status in_progress) BEFORE starting work
2. Close tasks (bd close <id> --reason \"...\") AFTER completing work
3. Your work is NOT complete until Beads is updated

IMPORTANT: At the END of your work, output a self-assessment report in this exact format:

<!--HIVE_REPORT
{
  \"status\": \"complete\",
  \"confidence\": 0.9,
  \"tasks_created\": [],
  \"tasks_closed\": [],
  \"files_modified\": [],
  \"decisions\": [],
  \"blockers\": [],
  \"summary\": \"Brief description of what you did\",
  \"next_agent_hint\": \"\"
}
HIVE_REPORT-->

Set status to: \"complete\" (all done), \"partial\" (some work done), \"blocked\" (can't proceed), or \"challenge\" (previous agent's work has a blocking problem).
Set confidence 0.0-1.0 based on how well the work went.
List ALL files you modified, tasks you created/closed, and any decisions made."
    
    local prompt_file=$(mktemp)
    echo "$full_prompt" > "$prompt_file"
    
    scratchpad_set_agent "$agent"
    log_agent_start "$agent"
    
    progress_status "Running $agent agent..." "work"
    
    local exit_code=0
    
    echo ""
    echo -e "${CYAN}━━━ $agent ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local agent_start=$(date +%s)
    
    # Reset file counter for this agent
    _PROGRESS_FILES_CHANGED=0
    
    set +e
    cat "$prompt_file" | claude -p --dangerously-skip-permissions 2>&1 | tee "$output_file"
    exit_code=$?
    set -e
    
    local agent_end=$(date +%s)
    local agent_duration=$((agent_end - agent_start))
    
    # Count files modified from output
    local files_in_output=$(grep -cE "^(Writing|Created|Modified|Wrote)" "$output_file" 2>/dev/null || echo "0")
    progress_set_files "$files_in_output"
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Duration with formatting
    local dur_min=$((agent_duration / 60))
    local dur_sec=$((agent_duration % 60))
    if [ $dur_min -gt 0 ]; then
        echo -e "${DIM}  ⏱ ${dur_min}m ${dur_sec}s${NC}"
    else
        echo -e "${DIM}  ⏱ ${dur_sec}s${NC}"
    fi
    
    # Quick stats from output
    local tasks_created=$(grep -c "bd create" "$output_file" 2>/dev/null || echo "0")
    local tasks_closed=$(grep -c "bd close" "$output_file" 2>/dev/null || echo "0")
    if [ "$tasks_created" -gt 0 ] || [ "$tasks_closed" -gt 0 ]; then
        echo -e "${DIM}  📋 ${tasks_created} created, ${tasks_closed} closed${NC}"
        progress_set_tasks "$tasks_created" "$tasks_closed"
    fi
    
    if [ "$files_in_output" -gt 0 ]; then
        echo -e "${DIM}  📁 ${files_in_output} files touched${NC}"
    fi
    
    # Record cost for this agent
    local run_id=$(scratchpad_get "run_id")
    if [ -n "$run_id" ]; then
        cost_record_from_files "$run_id" "$agent" "$prompt_file" "$output_file"
        cost_print_inline "$run_id"
    fi
    
    echo ""
    
    rm -f "$prompt_file"
    scratchpad_clear_agent
    
    export HIVE_LAST_AGENT_DURATION="$agent_duration"
    
    if [ -s "$output_file" ] && ! grep -q "TypeError:" "$output_file"; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Dynamic Workflow Adaptation
# ============================================================================

# Inject a phase into the workflow
workflow_inject_phase() {
    local phase_name="$1"
    local agent="$2"
    local reason="$3"

    local phase=$(jq -cn --arg n "$phase_name" --arg a "$agent" --arg r "$reason" \
        '{name: $n, agent: $a, required: false, injected: true, reason: $r}')

    scratchpad_update ".injected_phases = ((.injected_phases // []) + [$phase])"
    log_phase_injected "$phase_name" "$agent" "$reason"
    print_info "Injected phase: $phase_name ($reason)"
}

# Check conditions after each agent and adapt workflow
workflow_adapt_check() {
    local agent="$1"
    local report="$2"
    local run_id="$3"

    [ "${HIVE_ADAPT_ENABLED:-1}" != "1" ] && return 0

    # Trigger 1: Many files modified -> extra review
    local files_count=$(echo "$report" | jq '[.files_modified // []] | flatten | length' 2>/dev/null || echo "0")
    if [ "$files_count" -gt "${HIVE_ADAPT_MANY_FILES:-10}" ]; then
        log_smart_decision "adapt" "$(jq -cn --argjson n "$files_count" '{trigger: "many_files", count: $n}')"
        workflow_inject_phase "extra_review" "reviewer" "Extra review due to $files_count files modified"
    fi

    # Trigger 2: Repeated test failures -> escalate
    if [ "$agent" = "tester" ] || [ "$agent" = "e2e-tester" ]; then
        local status=$(echo "$report" | jq -r '.status // "unknown"')
        if [ "$status" = "blocked" ] || [ "$status" = "partial" ]; then
            local failures=$(scratchpad_get "test_failure_count" 2>/dev/null || echo "0")
            failures=$((failures + 1))
            scratchpad_set "test_failure_count" "$failures"

            if [ "$failures" -ge "${HIVE_ADAPT_MAX_FAILURES:-3}" ]; then
                log_smart_decision "adapt" "$(jq -cn --argjson n "$failures" '{trigger: "test_failures", count: $n}')"
                print_warn "Tests failed $failures times - escalating"
            fi
        fi
    fi

    # Trigger 3: Security issues -> add security phase
    local security_issues=$(echo "$report" | jq '[.issues_found // [] | .[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
    if [ "$security_issues" -gt 0 ] && [ "$agent" != "security" ]; then
        if ! scratchpad_get "security_phase_added" &>/dev/null; then
            log_smart_decision "adapt" "$(jq -cn --argjson n "$security_issues" '{trigger: "security_issues", count: $n}')"
            workflow_inject_phase "security_review" "security" "Security review due to $security_issues high/critical issues"
            scratchpad_set "security_phase_added" "true"
        fi
    fi
}

# ============================================================================
# Confidence-Gated Progression
# ============================================================================

# Check if confidence is below threshold and apply safety measures
confidence_gate_check() {
    local agent="$1"
    local confidence="$2"
    local run_id="$3"

    local threshold="${HIVE_CONFIDENCE_THRESHOLD:-0.6}"

    # Use awk for portable float comparison
    local is_low=$(awk -v c="$confidence" -v t="$threshold" 'BEGIN {print (c < t) ? 1 : 0}')

    if [ "$is_low" = "1" ]; then
        log_smart_decision "confidence" "$(jq -cn --arg a "$agent" --arg c "$confidence" --arg t "$threshold" \
            '{agent: $a, confidence: $c, threshold: $t, action: "safety_measures"}')"

        # 1. Disable parallel execution for remaining phases
        export HIVE_PARALLEL=0

        # 2. Mark for extra review
        scratchpad_set "needs_extra_review" "true"
        scratchpad_set "low_confidence_agent" "$agent"

        # 3. Trigger checkpoint if configured
        if [ "${HIVE_CONFIDENCE_CHECKPOINT:-1}" = "1" ] && [ "${HIVE_AUTO_MODE:-0}" != "1" ]; then
            print_warn "$agent reported low confidence ($confidence)"
            human_checkpoint "Low Confidence" "$agent reported confidence $confidence (threshold: $threshold). Review before continuing."
        fi

        return 1
    fi
    return 0
}

# ============================================================================
# Validation & Retry Loop (v2 - Self-Eval Primary)
# ============================================================================

run_agent_with_validation() {
    local agent="$1"
    local task="$2"
    local handoff_id="$3"
    
    local run_id=$(scratchpad_get "run_id")
    local output_dir="$HIVE_DIR/runs/$run_id/output"
    mkdir -p "$output_dir"
    
    local attempt=1
    local max_attempts=3
    
    local contract_attempts=$(contract_load "$agent" 2>/dev/null | jq -r '.on_failure.retry.max_attempts // 3' 2>/dev/null)
    if [ "$contract_attempts" -gt 0 ] 2>/dev/null; then
        max_attempts=$contract_attempts
    fi
    
    scratchpad_start_iteration "$agent"
    
    while [ $attempt -le $max_attempts ]; do
        local output_file="$output_dir/${agent}_attempt_${attempt}.md"
        
        print_info "Attempt $attempt of $max_attempts"
        
        if run_agent "$agent" "$task" "$handoff_id" "$output_file"; then
            local duration="${HIVE_LAST_AGENT_DURATION:-0}"
            
            # PRIMARY: Try self-eval first
            local report=$(selfeval_extract "$output_file")
            
            if [ -n "$report" ]; then
                selfeval_log "$agent" "$report"
                
                local eval_result=$(selfeval_passed "$report" "$agent")
                
                case "$eval_result" in
                    "pass"|"pass_low_confidence")
                        local confidence=$(echo "$report" | jq -r '.confidence // 0')
                        local summary=$(echo "$report" | jq -r '.summary // ""')

                        # Check confidence gate for safety measures
                        confidence_gate_check "$agent" "$confidence" "$run_id" || true

                        if [ "$eval_result" == "pass_low_confidence" ]; then
                            print_warn "$agent completed with low confidence ($confidence)"
                        else
                            print_success "$agent completed (confidence: $confidence)"
                        fi
                        
                        [ -n "$summary" ] && echo -e "  ${DIM}$summary${NC}"
                        
                        selfeval_apply_to_scratchpad "$report"
                        memory_learn_from_selfeval "$report"
                        memory_record_agent_run "$agent" "$duration" "true" "$attempt"
                        
                        log_agent_complete "$agent" true true
                        scratchpad_mark_agent_complete "$agent"
                        scratchpad_reset_iteration
                        export HIVE_LAST_SELFEVAL_REPORT="$report"
                        return 0
                        ;;
                    
                    "partial")
                        print_warn "$agent partially complete"
                        selfeval_apply_to_scratchpad "$report"
                        memory_learn_from_selfeval "$report"
                        memory_record_agent_run "$agent" "$duration" "true" "$attempt"
                        
                        log_agent_complete "$agent" true true
                        scratchpad_mark_agent_complete "$agent"
                        scratchpad_reset_iteration
                        export HIVE_LAST_SELFEVAL_REPORT="$report"
                        return 0
                        ;;
                    
                    "blocked")
                        local blockers=$(echo "$report" | jq -r '.blockers | join(", ")' 2>/dev/null || echo "unknown")
                        print_warn "$agent is blocked: $blockers"
                        selfeval_apply_to_scratchpad "$report"
                        memory_record_agent_run "$agent" "$duration" "false" "$attempt"
                        log_agent_complete "$agent" true false "Blocked: $blockers"
                        scratchpad_add_iteration_history "$agent" "blocked" "$blockers"
                        ;;

                    "challenge")
                        # Agent is challenging the previous agent's work
                        local challenged_agent=$(echo "$report" | jq -r '.challenged_agent // ""')
                        local issue=$(echo "$report" | jq -r '.issue // ""')
                        local suggestion=$(echo "$report" | jq -r '.suggestion // ""')
                        local evidence=$(echo "$report" | jq -r '.evidence // ""')

                        print_warn "$agent challenges $challenged_agent: $issue"

                        # Log the challenge
                        log_challenge "$agent" "$challenged_agent" "$issue" "$suggestion"

                        # Store challenge data for workflow loop to handle rerouting
                        export HIVE_CHALLENGE_FROM="$agent"
                        export HIVE_CHALLENGE_TO="$challenged_agent"
                        export HIVE_CHALLENGE_ISSUE="$issue"
                        export HIVE_CHALLENGE_SUGGESTION="$suggestion"
                        export HIVE_CHALLENGE_EVIDENCE="$evidence"
                        export HIVE_LAST_SELFEVAL_REPORT="$report"

                        memory_record_agent_run "$agent" "$duration" "false" "$attempt"
                        log_agent_complete "$agent" true false "Challenge: $issue"
                        scratchpad_reset_iteration

                        # Return special exit code 2 so workflow loop can handle rerouting
                        return 2
                        ;;

                    *)
                        # Fall through to legacy validation
                        ;;
                esac
            fi
            
            # FALLBACK: Legacy contract validation
            if [ -z "$report" ] || [ "$(selfeval_passed "$report" "$agent" 2>/dev/null)" == "unknown_status" ]; then
                local context=$(jq -n \
                    --arg epic_id "$(scratchpad_get "epic_id")" \
                    --arg handoff_path "$HIVE_DIR/handoffs/${handoff_id}.json" \
                    '{epic_id: $epic_id, handoff_path: $handoff_path}' 2>/dev/null \
                    || echo '{"epic_id": "", "handoff_path": ""}')
                
                local validation=$(validate_post "$agent" "$context" "$output_file")
                local valid=$(echo "$validation" | jq -r '.valid' 2>/dev/null || echo "true")
                
                if [ "$valid" == "true" ]; then
                    print_success "$agent completed (contract validated)"
                    memory_record_agent_run "$agent" "$duration" "true" "$attempt"
                    log_agent_complete "$agent" true true
                    scratchpad_mark_agent_complete "$agent"
                    scratchpad_reset_iteration
                    return 0
                else
                    local failed_checks=$(echo "$validation" | jq -r '[.checks[] | select(.passed == false) | .check] | join(", ")' 2>/dev/null || echo "unknown")
                    print_warn "Validation failed: $failed_checks"
                    log_agent_complete "$agent" true false "Validation failed: $failed_checks"
                    scratchpad_add_iteration_history "$agent" "validation_failed" "$failed_checks"
                fi
            fi
        else
            print_error "$agent failed"
            log_agent_complete "$agent" false false "Agent execution failed"
            scratchpad_add_iteration_history "$agent" "execution_failed" "Agent crashed or produced no output"
        fi
        
        # Retry logic
        if [ $attempt -lt $max_attempts ]; then
            print_warn "Retrying..."
            log_agent_retry "$agent" $attempt $max_attempts "Previous attempt failed"
            
            local feedback=$(contract_get_retry_feedback "$agent" "Previous attempt failed validation" $attempt 2>/dev/null || echo "Please try again.")
            task="$task

---
RETRY FEEDBACK (Attempt $((attempt + 1))):
$feedback

Previous output is in: $output_file"
            
            scratchpad_increment_attempt
        fi
        
        ((attempt++))
    done
    
    print_error "$agent failed after $max_attempts attempts"
    memory_record_agent_run "$agent" "0" "false" "$max_attempts"

    # Record failure in agent memory for pattern learning
    local last_report=$(selfeval_extract "$output_file" 2>/dev/null)
    if [ -n "$last_report" ]; then
        agent_memory_learn_from_report "$agent" "$last_report" "false"
    fi

    checkpoint_on_failure "$agent" "Max retries exceeded" $max_attempts

    return 1
}

# ============================================================================
# Challenge Rerouting
# ============================================================================

# Handle a challenge by re-running the challenged agent with challenge context
# Returns: 0 if challenge resolved, 1 if unresolved (needs human)
handle_challenge_reroute() {
    local challenging_agent="$1"
    local challenged_agent="$2"
    local issue="$3"
    local suggestion="$4"
    local evidence="$5"
    local epic_id="$6"
    local run_id="$7"
    local max_attempts="${HIVE_CHALLENGE_RETRY_ATTEMPTS:-2}"

    print_phase "Challenge: $challenging_agent → $challenged_agent"
    print_warn "Issue: $issue"
    [ -n "$suggestion" ] && print_info "Suggestion: $suggestion"

    local output_dir="$HIVE_DIR/runs/$run_id/output"
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        # Build challenge context with attempt info
        local challenge_task="## Challenge from $challenging_agent (Attempt $attempt/$max_attempts)

The **$challenging_agent** reviewed your work and found a blocking issue:

**Issue:** $issue

**Evidence:** $evidence

**Suggestion:** $suggestion

---

Address this challenge. Review the issue, update your work to resolve it, then output a new HIVE_REPORT.

If you believe the challenge is invalid, explain why in your HIVE_REPORT summary and set status to 'complete' with your rationale."

        # Add retry feedback for attempts > 1
        if [ $attempt -gt 1 ]; then
            challenge_task="$challenge_task

---
RETRY: Your previous response did not resolve the issue. Please:
1. Re-read the original issue carefully
2. Verify your fix directly addresses the stated problem
3. Reference the specific fix in your HIVE_REPORT summary"
        fi

        local challenge_output="$output_dir/${challenged_agent}_challenge_response_${attempt}.md"

        print_info "Re-running $challenged_agent to address challenge (attempt $attempt/$max_attempts)..."
        progress_status "Running $challenged_agent (challenge response $attempt/$max_attempts)..." "work"

        if run_agent "$challenged_agent" "$challenge_task" "" "$challenge_output"; then
            local response_report=$(selfeval_extract "$challenge_output")
            local response_status=$(echo "$response_report" | jq -r '.status // "unknown"')

            if [ "$response_status" == "complete" ] || [ "$response_status" == "partial" ]; then
                # Validate response addresses the specific issue
                if challenge_response_validates "$response_report" "$issue" "$evidence"; then
                    print_success "$challenged_agent addressed the challenge"
                    log_challenge_resolved "$challenging_agent" "$challenged_agent" "resolved" "$attempt"
                    # Record in memory for pattern learning
                    memory_record_challenge "$challenging_agent" "$challenged_agent" "$issue" "resolved"

                    # Update scratchpad with the response
                    selfeval_apply_to_scratchpad "$response_report"

                    # Clear challenge state
                    unset HIVE_CHALLENGE_FROM HIVE_CHALLENGE_TO HIVE_CHALLENGE_ISSUE HIVE_CHALLENGE_SUGGESTION HIVE_CHALLENGE_EVIDENCE
                    return 0
                fi
                print_warn "Response did not address the specific issue (attempt $attempt)"
            elif [ "$response_status" == "challenge" ]; then
                # Challenged agent is counter-challenging - escalate to human
                print_warn "$challenged_agent counter-challenged - escalating to human"
                log_challenge_resolved "$challenging_agent" "$challenged_agent" "escalated" "$attempt"
                memory_record_challenge "$challenging_agent" "$challenged_agent" "$issue" "escalated"
                return 1
            fi
        fi
        ((attempt++))
    done

    print_warn "$challenged_agent could not address challenge after $max_attempts attempts"
    log_challenge_resolved "$challenging_agent" "$challenged_agent" "unresolved" "$max_attempts"
    memory_record_challenge "$challenging_agent" "$challenged_agent" "$issue" "unresolved"
    return 1
}

# ============================================================================
# Human Checkpoint
# ============================================================================

human_checkpoint() {
    local checkpoint_type="$1"
    local message="$2"
    
    if [ "${HIVE_AUTO_MODE:-0}" == "1" ]; then
        print_info "Auto-mode: skipping checkpoint ($checkpoint_type)"
        return 0
    fi
    
    print_header "🛑 CHECKPOINT: $checkpoint_type"
    echo ""
    echo "$message"
    echo ""
    echo -e "${DIM}────────────────────────────────────────${NC}"
    
    log_human_checkpoint "$checkpoint_type" "$message"
    
    while true; do
        echo -e "${CYAN}[C]${NC}ontinue  ${CYAN}[S]${NC}cratchpad  ${CYAN}[B]${NC}eads  ${CYAN}[Q]${NC}uit"
        read -p "> " -n 1 -r REPLY < /dev/tty
        echo
        
        case $REPLY in
            [Cc])
                log_human_checkpoint "$checkpoint_type" "$message" "continue"
                return 0
                ;;
            [Ss])
                echo ""
                scratchpad_read | jq .
                echo ""
                ;;
            [Bb])
                echo ""
                bd list 2>/dev/null || echo "(unable to fetch)"
                echo ""
                ;;
            [Qq])
                log_human_checkpoint "$checkpoint_type" "$message" "quit"
                checkpoint_save "user_quit"
                return 1
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
    done
}

# ============================================================================
# Build Verification
# ============================================================================

run_build_check() {
    local epic_id="$1"
    local run_id="$2"
    
    print_phase "Build Verification"
    
    local build_cmd=$(memory_get_build_command)
    local build_passed=false
    
    if [ -n "$build_cmd" ] && [ "$build_cmd" != "" ]; then
        print_info "Build command (from memory): $build_cmd"
        if eval "$build_cmd" &>/dev/null; then
            build_passed=true
            print_success "Build passed"
        fi
    elif [ -f "package.json" ]; then
        local pkg=$(memory_get_package_manager)
        [ -z "$pkg" ] && pkg="npm"
        
        if $pkg run build &>/dev/null 2>&1; then
            build_passed=true
            print_success "Build passed"
        elif $pkg run typecheck &>/dev/null 2>&1; then
            build_passed=true
            print_success "Typecheck passed"
        fi
    elif [ -f "Cargo.toml" ]; then
        if cargo check &>/dev/null; then
            build_passed=true
            print_success "Build passed"
        fi
    elif [ -f "go.mod" ]; then
        if go build ./... &>/dev/null; then
            build_passed=true
            print_success "Build passed"
        fi
    else
        build_passed=true
        print_info "No build system detected"
    fi
    
    if [ "$build_passed" != "true" ]; then
        print_warn "Build failed, routing to debugger"
        local debug_handoff=$(handoff_to_debugger "build" "Build failed" "{}")
        
        if ! run_agent_with_validation "debugger" \
            "Fix the build errors. Run the build command and fix any issues." \
            "$debug_handoff"; then
            
            if ! human_checkpoint "Build Failed" "Build still failing after debugging. Continue anyway?"; then
                return 1
            fi
        fi
    fi
    
    return 0
}

run_fix_blockers() {
    local epic_id="$1"
    
    local blocking=$(bd list --json 2>/dev/null | jq '[.[] | select(.priority == 0 and (.status == "open" or .status == "ready"))] | length' 2>/dev/null || echo "0")
    
    if [ "$blocking" -gt 0 ] 2>/dev/null; then
        print_phase "Fix Blocking Issues"
        print_warn "Found $blocking blocking issues"
        
        if ! run_agent_with_validation "implementer" \
            "Fix the blocking (P0) issues.

Run bd ready and fix P0 issues only.
Close each after fixing." \
            ""; then
            
            if ! human_checkpoint "Blocking Issues" "Could not fix all blocking issues. Continue anyway?"; then
                return 1
            fi
        fi
    fi
    
    return 0
}

# ============================================================================
# Interview Phase - Clarify requirements before coding
# ============================================================================

run_interview() {
    local objective="$1"
    local epic_id="$2"
    
    print_phase "Interview"
    
    # Build prompt for Claude to generate questions
    local agent_prompt=""
    if [ -f "$HIVE_DIR/agents/interviewer.md" ]; then
        agent_prompt=$(cat "$HIVE_DIR/agents/interviewer.md")
    elif [ -f "$HIVE_ROOT/agents/interviewer.md" ]; then
        agent_prompt=$(cat "$HIVE_ROOT/agents/interviewer.md")
    else
        print_warn "Interviewer agent not found, skipping"
        return 0
    fi
    
    # Add project context
    local context=""
    local mem_context=$(memory_context_for_agent)
    [ -n "$mem_context" ] && context="$context\n\n$mem_context"
    
    if [ -f "CLAUDE.md" ]; then
        context="$context

## Project Guidelines (from CLAUDE.md)

$(cat CLAUDE.md)"
    fi
    
    local full_prompt="$agent_prompt
$context

---

OBJECTIVE: $objective

---

Generate your questions as a JSON array. Output ONLY the JSON, nothing else."
    
    # Call Claude to generate questions
    print_info "Analyzing objective for ambiguities..."
    
    local raw_output=$(echo "$full_prompt" | claude -p 2>/dev/null)
    
    # Extract JSON array from output (handle markdown code blocks)
    local questions=$(echo "$raw_output" \
        | sed -n '/^\[/,/^\]/p' \
        | head -200)
    
    # Try stripping code fences if no raw JSON found
    if [ -z "$questions" ] || ! echo "$questions" | jq empty 2>/dev/null; then
        questions=$(echo "$raw_output" \
            | sed -n '/```/,/```/p' \
            | sed '1d;$d' \
            | tr -d '\r')
    fi
    
    # Validate JSON
    if [ -z "$questions" ] || ! echo "$questions" | jq empty 2>/dev/null; then
        print_warn "Could not parse interview questions, skipping"
        return 0
    fi
    
    local question_count=$(echo "$questions" | jq 'length' 2>/dev/null || echo "0")
    
    if [ "$question_count" -eq 0 ] 2>/dev/null; then
        print_success "Objective is clear — no questions needed"
        return 0
    fi
    
    # Display and collect answers
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${CYAN}? $question_count question(s) to clarify the objective${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    local answers=""
    local q_idx=0
    
    while [ $q_idx -lt $question_count ]; do
        local q_json=$(echo "$questions" | jq -c ".[$q_idx]")
        local q_text=$(echo "$q_json" | jq -r '.question')
        local q_why=$(echo "$q_json" | jq -r '.why // ""')
        local option_count=$(echo "$q_json" | jq '.options | length')
        
        echo -e "${BOLD}Q$((q_idx + 1)). $q_text${NC}"
        [ -n "$q_why" ] && [ "$q_why" != "" ] && echo -e "    ${DIM}($q_why)${NC}"
        echo ""
        
        # Display options
        local opt_idx=0
        while [ $opt_idx -lt $option_count ]; do
            local opt_key=$(echo "$q_json" | jq -r ".options[$opt_idx].key")
            local opt_label=$(echo "$q_json" | jq -r ".options[$opt_idx].label")
            local opt_freetext=$(echo "$q_json" | jq -r ".options[$opt_idx].freetext // false")
            
            if [ "$opt_freetext" == "true" ]; then
                echo -e "    ${CYAN}${opt_key})${NC} ${opt_label} (type your answer)"
            else
                echo -e "    ${CYAN}${opt_key})${NC} ${opt_label}"
            fi
            
            opt_idx=$((opt_idx + 1))
        done
        
        echo ""
        
        # Collect answer
        local valid_answer=false
        while [ "$valid_answer" != "true" ]; do
            read -p "  > " -r REPLY < /dev/tty
            REPLY=$(echo "$REPLY" | tr '[:upper:]' '[:lower:]' | xargs)
            
            if [ -z "$REPLY" ]; then
                echo "  Please enter an option."
                continue
            fi
            
            # Check if it matches an option key
            local matched_opt=""
            local is_freetext="false"
            opt_idx=0
            while [ $opt_idx -lt $option_count ]; do
                local opt_key=$(echo "$q_json" | jq -r ".options[$opt_idx].key")
                local opt_ft=$(echo "$q_json" | jq -r ".options[$opt_idx].freetext // false")
                
                if [ "$REPLY" == "$opt_key" ]; then
                    matched_opt=$(echo "$q_json" | jq -r ".options[$opt_idx].label")
                    is_freetext="$opt_ft"
                    break
                fi
                opt_idx=$((opt_idx + 1))
            done
            
            if [ -n "$matched_opt" ]; then
                if [ "$is_freetext" == "true" ]; then
                    echo -e "    ${DIM}Type your answer:${NC}"
                    read -p "  > " -r FREETEXT < /dev/tty
                    if [ -n "$FREETEXT" ]; then
                        answers="${answers}
- ${q_text}: ${FREETEXT}"
                    else
                        answers="${answers}
- ${q_text}: ${matched_opt}"
                    fi
                else
                    answers="${answers}
- ${q_text}: ${matched_opt}"
                fi
                valid_answer=true
            else
                # Treat raw text as a freetext answer
                answers="${answers}
- ${q_text}: ${REPLY}"
                valid_answer=true
            fi
        done
        
        echo ""
        q_idx=$((q_idx + 1))
    done
    
    # Enrich the objective with answers
    if [ -n "$answers" ]; then
        local enriched_objective="$objective

## Clarifications
$answers"
        
        scratchpad_set "objective" "$enriched_objective"
        
        echo "────────────────────────────────────────"
        echo -e "${GREEN}✓ Objective enriched with $question_count answer(s)${NC}"
        echo ""
    fi
    
    return 0
}

# ============================================================================
# Issue Triage - Route reviewer/tester issues back to implementer
# ============================================================================

# Check if the last agent's report has issues and prompt user for action
# Returns: 0 = continue, 1 = user quit
# Sets HIVE_TRIAGE_ACTION to "fix" if routing back to implementer
issue_triage() {
    local agent="$1"
    local epic_id="$2"
    local run_id="$3"
    
    # Only triage for reviewer and security agents
    if [[ "$agent" != "reviewer" && "$agent" != "security" ]]; then
        return 0
    fi
    
    # Get the agent's output file
    local output_file="$HIVE_DIR/runs/$run_id/output/${agent}.txt"
    
    if [ ! -f "$output_file" ]; then
        return 0
    fi
    
    # Process findings and launch triage UI
    if ! findings_process_and_triage "$output_file" "$run_id" "$epic_id"; then
        # User quit or blocker in auto mode
        return 1
    fi
    
    return 0
}

# ============================================================================
# Single Agent Execution (--only mode)
# ============================================================================

run_single_agent() {
    local objective="$1"
    local agent="$2"
    
    # Validate agent exists (check local override first, then installed)
    local agent_file=""
    if [ -f "$HIVE_DIR/agents/${agent}.md" ]; then
        agent_file="$HIVE_DIR/agents/${agent}.md"
    elif [ -f "$HIVE_ROOT/agents/${agent}.md" ]; then
        agent_file="$HIVE_ROOT/agents/${agent}.md"
    fi
    
    if [ -z "$agent_file" ]; then
        print_error "Unknown agent: $agent"
        echo ""
        echo "Available agents:"
        for f in "$HIVE_ROOT"/agents/*.md; do
            [ -f "$f" ] || continue
            local name=$(basename "$f" .md)
            echo "  $name"
        done
        return 1
    fi
    
    local run_id=$(date +"%Y%m%d_%H%M%S")
    local run_start=$(date +%s)
    
    # Initialize progress tracking
    progress_init
    progress_set_agent "$agent"
    progress_set_phase "single agent"
    
    print_header "🐝 HIVE - Single Agent"
    print_info "Objective: $objective"
    print_info "Agent: $agent"
    print_info "Run ID: $run_id"
    
    # Initialize directories
    mkdir -p "$HIVE_DIR/runs/$run_id/output"
    mkdir -p "$HIVE_DIR/runs/$run_id/snapshots"
    mkdir -p "$HIVE_DIR/handoffs"
    mkdir -p "$HIVE_DIR/checkpoints"
    
    # Initialize project memory
    memory_init
    memory_detect_project
    
    # Build codebase index
    index_build
    
    # Create or reuse epic
    local epic_id=""
    local existing_epics=$(bd list --json 2>/dev/null | jq -r '[.[] | select(.type == "epic")] | length' 2>/dev/null || echo "0")
    if [ "$existing_epics" -gt 0 ] 2>/dev/null; then
        epic_id=$(bd list --json 2>/dev/null | jq -r '[.[] | select(.type == "epic")] | last | .id' 2>/dev/null || echo "")
        print_info "Using existing epic: $epic_id"
    else
        epic_id=$(beads_create_epic "Solo: $objective" "$objective")
        print_info "Created epic: $epic_id"
    fi
    
    # Initialize scratchpad
    scratchpad_init "$run_id" "$epic_id" "$objective"
    log_run_start "$run_id" "$objective"
    
    # Take snapshot
    diff_snapshot "before_${agent}" "$run_id"
    
    # Run agent
    print_phase "Running $agent"
    scratchpad_set_phase "$agent"
    
    if ! run_agent_with_validation "$agent" "$objective" ""; then
        print_warn "$agent had issues"
    fi
    
    # Snapshot after
    diff_snapshot "after_${agent}" "$run_id"
    
    # Timing
    local run_end=$(date +%s)
    local duration=$((run_end - run_start))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    
    # Summary
    print_header "✓ Agent Complete"
    print_info "Agent: $agent"
    print_info "Time: ${mins}m ${secs}s"
    
    local open_tasks=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "open" or .status == "ready")] | length' 2>/dev/null || echo "?")
    local closed_tasks=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "closed")] | length' 2>/dev/null || echo "?")
    print_info "Tasks closed: $closed_tasks | open: $open_tasks"
    
    scratchpad_set_status "complete"
    log_run_complete "$run_id" true "Single agent run: $agent"
    
    # Generate post-mortem
    postmortem_generate "$run_id" "$objective" "$epic_id"
    
    echo ""
    echo -e "${DIM}Run 'hive report' for details${NC}"
}

# ============================================================================
# Workflow-Driven Execution (v2)
# ============================================================================

run_workflow() {
    local objective="$1"
    local workflow_type="${2:-feature}"
    
    local run_id=$(date +"%Y%m%d_%H%M%S")
    local workflow_start=$(date +%s)
    
    # Initialize progress tracking
    progress_init
    
    print_header "🐝 HIVE - Starting Workflow"
    print_info "Objective: $objective"
    print_info "Workflow: $workflow_type"
    print_info "Run ID: $run_id"
    
    # Validate workflow
    local workflow_def=$(workflow_get "$workflow_type")
    if [ -z "$workflow_def" ]; then
        print_error "Unknown workflow: $workflow_type"
        echo ""
        workflow_list
        return 1
    fi
    
    local workflow_agents=$(echo "$workflow_def" | jq -r '[.phases[] | select(.agent != null) | .agent] | join(" → ")')
    print_info "Pipeline: $workflow_agents"
    
    # Initialize directories
    mkdir -p "$HIVE_DIR/runs/$run_id/output"
    mkdir -p "$HIVE_DIR/runs/$run_id/snapshots"
    mkdir -p "$HIVE_DIR/handoffs"
    mkdir -p "$HIVE_DIR/checkpoints"
    
    # Initialize cost tracking
    cost_init "$run_id"
    
    # Initialize git integration
    if [ "${HIVE_GIT:-1}" = "1" ]; then
        git_init_run "$objective" "$run_id" || true
    fi
    
    # Load smart context based on objective
    local smart_context=$(smart_load_context "$objective")
    if [ -n "$smart_context" ]; then
        print_info "Loaded relevant context for objective"
    fi
    
    # Initialize project memory
    memory_init
    memory_detect_project
    memory_increment_runs
    
    # Build codebase index
    print_info "Indexing codebase..."
    index_build
    
    local run_count=$(memory_read | jq '.run_count')
    if [ "$run_count" -gt 1 ] 2>/dev/null; then
        print_info "Project memory: run #$run_count"
    fi
    
    # Create epic
    print_phase "Creating Epic in Beads"
    local epic_id=$(beads_create_epic "Epic: $objective" "$objective")
    
    if [ -z "$epic_id" ]; then
        print_error "Failed to create epic"
        return 1
    fi
    print_success "Created epic: $epic_id"
    
    # Initialize scratchpad
    scratchpad_init "$run_id" "$epic_id" "$objective"
    log_run_start "$run_id" "$objective"
    
    # Take initial snapshot
    diff_snapshot "initial" "$run_id"
    
    # Detect project
    local has_frontend=$(detect_frontend)
    local test_strategy=$(detect_test_strategy)
    local has_tests=$(echo "$test_strategy" | jq -r '.has_tests // false')
    
    # Ensure boolean values are valid JSON
    [[ "$has_frontend" != "true" ]] && has_frontend="false"
    [[ "$has_tests" != "true" ]] && has_tests="false"
    
    local workflow_context="{\"has_frontend\": $has_frontend, \"has_tests\": $has_tests}"
    
    print_info "Frontend detected: $has_frontend"
    
    # ─────────────────────────────────────────────────────────
    # Execute workflow phases
    # ─────────────────────────────────────────────────────────
    
    local phase_num=1
    local total_phases=$(echo "$workflow_def" | jq '.phases | length')
    local last_agent=""
    
    # Write phases to temp file to avoid subshell from pipe
    local phases_file=$(mktemp)
    echo "$workflow_def" | jq -c '.phases[]' > "$phases_file"
    
    while IFS= read -r phase_json; do
        # Check for injected phases first (from workflow adaptation)
        local injected=$(scratchpad_get "injected_phases" 2>/dev/null | jq -c '.[0] // empty' 2>/dev/null)
        if [ -n "$injected" ] && [ "$injected" != "null" ] && [ "$injected" != "" ]; then
            # Pop first injected phase and use it instead
            scratchpad_update '.injected_phases = (.injected_phases[1:] // [])'
            phase_json="$injected"
            print_info "Processing injected phase..."
        fi

        local phase_name=$(echo "$phase_json" | jq -r '.name')
        local phase_type=$(echo "$phase_json" | jq -r '.type // "agent"')
        local phase_agent=$(echo "$phase_json" | jq -r '.agent // ""')
        local phase_required=$(echo "$phase_json" | jq -r '.required // true')
        local phase_task=$(echo "$phase_json" | jq -r '.task // ""')
        local phase_condition=$(echo "$phase_json" | jq -r '.condition // ""')
        local needs_handoff=$(echo "$phase_json" | jq -r '.needs_handoff_from // ""')
        local checkpoint_after=$(echo "$phase_json" | jq -r '.human_checkpoint_after // false')
        local on_failure=$(echo "$phase_json" | jq -r '.on_failure // ""')
        
        # Check condition
        if [ -n "$phase_condition" ] && [ "$phase_condition" != "null" ]; then
            local should_run=$(workflow_phase_should_run "$phase_json" "$workflow_context")
            if [ "$should_run" != "true" ]; then
                print_info "Skipping $phase_name (condition not met)"
                phase_num=$((phase_num + 1))
                continue
            fi
        fi
        
        # Special phase types
        case "$phase_type" in
            "build_verify")
                run_build_check "$epic_id" "$run_id"
                diff_snapshot "after_build" "$run_id"
                phase_num=$((phase_num + 1))
                continue
                ;;
            "fix_blocking")
                run_fix_blockers "$epic_id"
                phase_num=$((phase_num + 1))
                continue
                ;;
            "interview")
                if [ "${HIVE_AUTO_MODE:-0}" != "1" ] && [ "${HIVE_NO_INTERVIEW:-0}" != "1" ]; then
                    run_interview "$objective" "$epic_id"
                    # Interview enriches the objective in scratchpad
                    objective=$(scratchpad_get "objective")
                else
                    print_info "Skipping interview"
                fi
                phase_num=$((phase_num + 1))
                continue
                ;;
        esac
        
        # Agent phase
        print_phase "Phase $phase_num/$total_phases: ${phase_name}"
        scratchpad_set_phase "$phase_name"
        progress_set_agent "$phase_agent"
        progress_set_phase "$phase_name ($phase_num/$total_phases)"

        # Cost-aware budget check
        if [ "${HIVE_COST_AWARE:-0}" = "1" ]; then
            local spent=$(cost_get_total "$run_id")
            if ! cost_fits_budget "$phase_agent" "$spent"; then
                if [ "$phase_required" != "true" ]; then
                    log_smart_decision "budget" "$(jq -cn --arg a "$phase_agent" --arg s "$spent" '{agent: $a, spent: $s, action: "skipped"}')"
                    print_warn "Skipping $phase_agent (over budget)"
                    phase_num=$((phase_num + 1))
                    continue
                else
                    print_warn "Budget exceeded but $phase_agent is required"
                fi
            fi
        fi

        # Predictive agent skipping (fast mode)
        if [ "${HIVE_FAST_MODE:-0}" = "1" ] && [ "$phase_required" != "true" ]; then
            if memory_is_skip_safe "$phase_agent" "$objective"; then
                log_smart_decision "skip" "$(jq -cn --arg a "$phase_agent" '{agent: $a, reason: "high_success_pattern"}')"
                print_info "Skipping $phase_agent (fast mode: high success pattern)"
                phase_num=$((phase_num + 1))
                continue
            fi
        fi

        # Template variables
        phase_task="${phase_task//\{\{EPIC_ID\}\}/$epic_id}"
        [ -z "$phase_task" ] && phase_task="Execute your role for: $objective"

        # Build handoff
        local handoff_id=""
        if [ -n "$needs_handoff" ] && [ "$needs_handoff" != "null" ]; then
            # Check for pair performance warnings
            local pair_warning=$(memory_get_pair_warning "$needs_handoff" "$phase_agent")
            if [ -n "$pair_warning" ]; then
                print_warn "$pair_warning"
            fi

            case "${needs_handoff}_${phase_agent}" in
                architect_implementer)
                    handoff_id=$(handoff_architect_to_implementer "Ready for implementation" "$epic_id")
                    ;;
                implementer_tester|implementer_e2e-tester|implementer_component-tester)
                    handoff_id=$(handoff_implementer_to_tester "Testing needed" "[]" "$epic_id")
                    ;;
                implementer_ui-designer)
                    handoff_id=$(handoff_implementer_to_ui_designer "UI review needed" "[]" "$epic_id")
                    ;;
                *)
                    handoff_id=$(handoff_create "$needs_handoff" "$phase_agent" "Handoff for $phase_name" "" "$epic_id")
                    ;;
            esac
        fi
        
        # Run agent and capture exit code
        local agent_exit_code=0
        run_agent_with_validation "$phase_agent" "$phase_task" "$handoff_id" || agent_exit_code=$?

        # Handle challenge (exit code 2)
        if [ "$agent_exit_code" -eq 2 ] && [ -n "${HIVE_CHALLENGE_FROM:-}" ]; then
            local challenged_agent="${HIVE_CHALLENGE_TO:-}"
            local challenge_issue="${HIVE_CHALLENGE_ISSUE:-}"
            local challenge_suggestion="${HIVE_CHALLENGE_SUGGESTION:-}"
            local challenge_evidence="${HIVE_CHALLENGE_EVIDENCE:-}"

            # Configurable challenge limit per handoff (default: 2)
            local max_challenges="${HIVE_MAX_CHALLENGES:-2}"

            # Check how many challenges we've done for this handoff
            local challenge_loop_key="challenge_${phase_agent}_${challenged_agent}"
            local challenge_count=$(scratchpad_get "$challenge_loop_key" 2>/dev/null || echo "0")
            challenge_count=$((challenge_count + 0))  # Ensure numeric

            if [ "$challenge_count" -ge "$max_challenges" ]; then
                # Challenge limit reached - escalate to human
                print_warn "Challenge limit reached ($max_challenges per handoff)"
                if ! human_checkpoint "Challenge Unresolved" "$phase_agent challenged $challenged_agent but issue persists after $challenge_count attempt(s). Continue anyway?

Issue: $challenge_issue

Suggestion: $challenge_suggestion"; then
                    rm -f "$phases_file"
                    return 1
                fi
                # Clear challenge state and continue
                unset HIVE_CHALLENGE_FROM HIVE_CHALLENGE_TO HIVE_CHALLENGE_ISSUE HIVE_CHALLENGE_SUGGESTION HIVE_CHALLENGE_EVIDENCE
            else
                # Under limit - attempt reroute
                scratchpad_set "$challenge_loop_key" "$((challenge_count + 1))"

                if handle_challenge_reroute "$phase_agent" "$challenged_agent" "$challenge_issue" "$challenge_suggestion" "$challenge_evidence" "$epic_id" "$run_id"; then
                    # Challenge resolved - re-run the challenging agent
                    print_info "Re-running $phase_agent after challenge resolution..."
                    progress_status "Running $phase_agent (post-challenge)..." "work"

                    # Re-run the challenging agent
                    if ! run_agent_with_validation "$phase_agent" "$phase_task" "$handoff_id"; then
                        if [ "$phase_required" == "true" ]; then
                            if ! human_checkpoint "${phase_name} Failed" "$phase_agent failed after challenge resolution. Continue anyway?"; then
                                rm -f "$phases_file"
                                return 1
                            fi
                        else
                            print_warn "$phase_name had issues, continuing..."
                        fi
                    fi
                else
                    # Challenge not resolved - escalate to human
                    if ! human_checkpoint "Challenge Unresolved" "$phase_agent challenged $challenged_agent. Challenge could not be resolved automatically.

Issue: $challenge_issue

Suggestion: $challenge_suggestion

Continue anyway?"; then
                        rm -f "$phases_file"
                        return 1
                    fi
                fi
            fi
        elif [ "$agent_exit_code" -ne 0 ]; then
            # Normal failure handling
            if [ -n "$on_failure" ] && [ "$on_failure" != "null" ]; then
                print_warn "$phase_name failed, routing to $on_failure"
                local debug_handoff=$(handoff_to_debugger "$phase_agent" "$phase_name failed" "{}")
                run_agent_with_validation "$on_failure" "Fix the failures from $phase_name" "$debug_handoff"
            elif [ "$phase_required" == "true" ]; then
                if ! human_checkpoint "${phase_name} Failed" "$phase_agent failed. Continue anyway?"; then
                    rm -f "$phases_file"
                    return 1
                fi
            else
                print_warn "$phase_name had issues, continuing..."
            fi
        fi
        
        # Snapshot, update index, and checkpoint
        diff_snapshot "after_${phase_name}" "$run_id"
        index_update
        checkpoint_save "after_${phase_name}"
        
        # Git commit after successful agent
        if [ -n "$phase_agent" ]; then
            local agent_summary=$(selfeval_extract "$HIVE_DIR/runs/$run_id/output/${phase_agent}.txt" | jq -r '.summary // "Completed phase"' 2>/dev/null | head -c 50)
            git_commit_phase "$phase_agent" "${agent_summary:-Completed $phase_name}" "$run_id"

            # Update agent memory
            local report=$(selfeval_extract "$HIVE_DIR/runs/$run_id/output/${phase_agent}.txt" 2>/dev/null)
            if [ -n "$report" ]; then
                agent_memory_learn_from_report "$phase_agent" "$report" "true"
                # Check for workflow adaptation triggers
                workflow_adapt_check "$phase_agent" "$report" "$run_id"

                # Record outcome for predictive skipping
                local was_challenged="false"
                [ -n "${HIVE_CHALLENGE_FROM:-}" ] && was_challenged="true"
                memory_record_skip_outcome "$phase_agent" "$objective" "true" "$was_challenged"

                # Record pair performance for handoff patterns
                if [ -n "$last_agent" ]; then
                    memory_record_pair_performance "$last_agent" "$phase_agent" "$was_challenged"
                fi
            fi
        fi
        
        # Issue triage for reviewers and security
        if [[ "$phase_agent" == "reviewer" || "$phase_agent" == "security" ]]; then
            if ! issue_triage "$phase_agent" "$epic_id" "$run_id"; then
                rm -f "$phases_file"
                return 1
            fi
        fi
        
        # Human checkpoint if configured
        if [ "$checkpoint_after" == "true" ]; then
            # Get last agent's report for summary
            local last_output="$HIVE_DIR/runs/$run_id/output/${phase_agent}.txt"
            local confidence=""
            local summary=""
            local files_modified=""
            local issues=""
            
            if [ -f "$last_output" ]; then
                local report=$(selfeval_extract "$last_output")
                if [ -n "$report" ]; then
                    confidence=$(echo "$report" | jq -r '.confidence // ""')
                    summary=$(echo "$report" | jq -r '.summary // ""')
                    files_modified=$(echo "$report" | jq -r '.files_modified // .files_created // "[]"')
                    issues=$(echo "$report" | jq -r '.issues_found // .vulnerabilities // "[]"')
                fi
            fi
            
            # Show enhanced checkpoint display
            progress_checkpoint_display "$phase_agent" "${confidence:-0.8}" "$files_modified" "$issues" "$summary"
            
            if ! human_checkpoint "${phase_name} Review" ""; then
                rm -f "$phases_file"
                return 1
            fi
        fi
        
        last_agent="$phase_agent"
        phase_num=$((phase_num + 1))
    done < "$phases_file"
    
    rm -f "$phases_file"
    
    # ─────────────────────────────────────────────────────────
    # COMPLETE
    # ─────────────────────────────────────────────────────────
    
    local workflow_end=$(date +%s)
    local total_duration=$((workflow_end - workflow_start))
    local total_mins=$((total_duration / 60))
    local total_secs=$((total_duration % 60))
    
    print_header "🎉 Workflow Complete"
    
    scratchpad_set_status "complete"
    scratchpad_set_phase "complete"
    progress_set_agent ""
    progress_set_phase "complete"
    
    local open_tasks=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "open" or .status == "ready")] | length' 2>/dev/null || echo "?")
    local closed_tasks=$(bd list --json 2>/dev/null | jq '[.[] | select(.status == "closed")] | length' 2>/dev/null || echo "?")
    
    log_run_complete "$run_id" true "Completed with $closed_tasks tasks closed, $open_tasks remaining"
    
    # Final progress summary
    progress_print_summary
    
    print_info "Epic: $epic_id"
    print_info "Tasks closed: $closed_tasks"
    print_info "Tasks remaining: $open_tasks"
    print_info "Total time: ${total_mins}m ${total_secs}s"
    
    # Cost summary
    local total_cost=$(cost_get_total "$run_id")
    print_info "Total cost: \$$(format_cost $total_cost)"
    
    # Save cost to history
    cost_save_to_history "$run_id"
    
    # Generate post-mortem
    echo ""
    local report_file=$(postmortem_generate "$run_id" "$epic_id")
    print_info "Report: $report_file"

    # Aggregate agent patterns for compounding knowledge
    memory_aggregate_agent_patterns "$run_id"

    # Update CLAUDE.md with learnings
    update_claude_md_from_run "$run_id" "$epic_id"

    echo ""
    echo -e "${BOLD}Agent Summary:${NC}"
    postmortem_print_summary "$run_id" "$epic_id"
    
    print_info "Run directory: $HIVE_DIR/runs/$run_id"
    
    checkpoint_save "complete"
    
    # Git finalize - offer to create PR
    git_finalize_run "$run_id" "$epic_id" "$objective"
    
    return 0
}

# ============================================================================
# Resume Workflow
# ============================================================================

resume_workflow() {
    local checkpoint_id="${1:-$(checkpoint_latest)}"
    
    if [ -z "$checkpoint_id" ]; then
        print_error "No checkpoint found to resume from"
        return 1
    fi
    
    print_header "🐝 HIVE - Resuming Workflow"
    print_info "Checkpoint: $checkpoint_id"
    
    local restore_info=$(checkpoint_restore "$checkpoint_id")
    
    local run_id=$(echo "$restore_info" | jq -r '.run_id')
    local epic_id=$(echo "$restore_info" | jq -r '.epic_id')
    local objective=$(echo "$restore_info" | jq -r '.objective')
    local phase=$(echo "$restore_info" | jq -r '.current_phase')
    
    print_info "Run ID: $run_id"
    print_info "Epic: $epic_id"
    print_info "Objective: $objective"
    print_info "Resuming from phase: $phase"
    
    local resume_action=$(checkpoint_get_resume_action "$checkpoint_id")
    local action=$(echo "$resume_action" | jq -r '.action')
    
    print_info "Action: $action"
    log_checkpoint_restored "$checkpoint_id"
    
    case "$action" in
        "none")
            print_success "Workflow already complete"
            return 0
            ;;
        "escalate")
            if ! human_checkpoint "Max Retries" "Previous agent exceeded max retries. How to proceed?"; then
                return 1
            fi
            scratchpad_reset_iteration
            ;;
        "retry_agent"|"continue_phase")
            print_info "Continuing..."
            ;;
    esac
    
    case "$phase" in
        "init"|"design")
            run_workflow "$objective"
            ;;
        *)
            print_warn "Resume from $phase not fully implemented"
            print_info "Consider running: hive run \"$objective\""
            ;;
    esac
}
