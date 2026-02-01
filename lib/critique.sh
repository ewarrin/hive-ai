#!/usr/bin/env bash
# Hive Critique - Agent self-reflection before finalizing output
#
# Agents output a HIVE_CRITIQUE block before their HIVE_REPORT.
# This enables self-correction loops where agents can revise their work
# before submitting the final report.
#
# Format agents should output:
#
#   <!--HIVE_CRITIQUE
#   {
#     "critique_passed": true,
#     "checks_completed": ["builds", "tests_pass", "matches_spec"],
#     "checks_failed": [],
#     "issues_found": [{"issue": "Missing error handling", "severity": "medium", "fixable": true}],
#     "confidence_adjustment": 0,
#     "ready_to_submit": true
#   }
#   HIVE_CRITIQUE-->

HIVE_DIR="${HIVE_DIR:-.hive}"

# ============================================================================
# Agent-Specific Checklists
# ============================================================================

# Get the default checklist for an agent type
critique_get_checklist() {
    local agent="$1"

    case "$agent" in
        architect)
            cat <<'EOF'
[
  {"id": "objective_clear", "check": "Does the design address the original objective?"},
  {"id": "tasks_actionable", "check": "Are all tasks specific and actionable?"},
  {"id": "dependencies_mapped", "check": "Are task dependencies correctly identified?"},
  {"id": "patterns_followed", "check": "Does the design follow existing codebase patterns?"},
  {"id": "edge_cases", "check": "Are edge cases and error scenarios considered?"},
  {"id": "scope_appropriate", "check": "Is the scope appropriate (not too large, not too small)?"}
]
EOF
            ;;
        implementer)
            cat <<'EOF'
[
  {"id": "builds", "check": "Does the code compile/parse without errors?"},
  {"id": "tests_pass", "check": "Do existing tests still pass?"},
  {"id": "matches_spec", "check": "Does implementation match the task specification?"},
  {"id": "patterns_followed", "check": "Does code follow existing patterns in the codebase?"},
  {"id": "edge_cases", "check": "Are edge cases handled (null, empty, errors)?"},
  {"id": "no_debug_code", "check": "Is there no console.log/debug/TODO code left?"}
]
EOF
            ;;
        tester)
            cat <<'EOF'
[
  {"id": "coverage", "check": "Do tests cover the main functionality?"},
  {"id": "edge_cases", "check": "Are edge cases tested?"},
  {"id": "tests_pass", "check": "Do all new tests pass?"},
  {"id": "readable", "check": "Are test names descriptive?"},
  {"id": "isolated", "check": "Are tests isolated (no external dependencies)?"}
]
EOF
            ;;
        reviewer)
            cat <<'EOF'
[
  {"id": "thorough", "check": "Did I review all changed files?"},
  {"id": "categorized", "check": "Are findings properly categorized by severity?"},
  {"id": "actionable", "check": "Are findings specific and actionable?"},
  {"id": "no_nitpicks", "check": "Am I focusing on real issues, not style nitpicks?"},
  {"id": "security_checked", "check": "Did I check for security issues?"}
]
EOF
            ;;
        security)
            cat <<'EOF'
[
  {"id": "injection", "check": "Did I check for injection vulnerabilities?"},
  {"id": "auth", "check": "Did I verify authentication/authorization?"},
  {"id": "data_exposure", "check": "Did I check for data exposure risks?"},
  {"id": "dependencies", "check": "Did I check for vulnerable dependencies?"},
  {"id": "actionable", "check": "Are findings specific and actionable?"}
]
EOF
            ;;
        *)
            # Generic checklist for unknown agents
            cat <<'EOF'
[
  {"id": "objective_met", "check": "Does the output meet the objective?"},
  {"id": "quality", "check": "Is the output quality acceptable?"},
  {"id": "complete", "check": "Is the work complete?"}
]
EOF
            ;;
    esac
}

# ============================================================================
# Critique Validation
# ============================================================================

# Validate HIVE_CRITIQUE format
critique_validate_format() {
    local critique="$1"

    if [ -z "$critique" ]; then
        echo '{"valid": false, "reason": "No critique found"}'
        return 1
    fi

    # Check required fields
    local has_passed=$(echo "$critique" | jq 'has("critique_passed")')
    local has_ready=$(echo "$critique" | jq 'has("ready_to_submit")')

    if [ "$has_passed" == "true" ] && [ "$has_ready" == "true" ]; then
        echo '{"valid": true}'
        return 0
    fi

    local missing="[]"
    [ "$has_passed" != "true" ] && missing=$(echo "$missing" | jq '. += ["critique_passed"]')
    [ "$has_ready" != "true" ] && missing=$(echo "$missing" | jq '. += ["ready_to_submit"]')

    jq -n --argjson missing "$missing" '{"valid": false, "reason": "Missing fields", "missing": $missing}'
    return 1
}

# Determine if agent should retry based on critique
critique_should_retry() {
    local critique="$1"

    if [ -z "$critique" ]; then
        # No critique = don't retry (legacy behavior)
        echo "false"
        return 0
    fi

    local critique_passed=$(echo "$critique" | jq -r '.critique_passed // true')
    local ready_to_submit=$(echo "$critique" | jq -r '.ready_to_submit // true')

    # Check for fixable issues
    local fixable_issues=$(echo "$critique" | jq '[.issues_found // [] | .[] | select(.fixable == true and .severity != "low")] | length')

    if [ "$critique_passed" == "false" ] || [ "$ready_to_submit" == "false" ]; then
        # Agent flagged their own work as not ready
        echo "true"
        return 0
    fi

    if [ "$fixable_issues" -gt 0 ]; then
        # There are fixable issues the agent identified
        echo "true"
        return 0
    fi

    echo "false"
    return 0
}

# Get retry feedback from critique
critique_get_retry_feedback() {
    local critique="$1"
    local agent="$2"

    if [ -z "$critique" ]; then
        echo "No critique available."
        return 0
    fi

    local failed_checks=$(echo "$critique" | jq -r '.checks_failed // [] | join(", ")')
    local issues=$(echo "$critique" | jq -r '[.issues_found // [] | .[] | .issue] | join("; ")')

    local feedback="Your self-critique identified the following issues:\n"

    if [ -n "$failed_checks" ] && [ "$failed_checks" != "" ]; then
        feedback="${feedback}- Failed checks: ${failed_checks}\n"
    fi

    if [ -n "$issues" ] && [ "$issues" != "" ]; then
        feedback="${feedback}- Issues found: ${issues}\n"
    fi

    feedback="${feedback}\nPlease address these issues before submitting your final output."

    echo -e "$feedback"
}

# ============================================================================
# Critique Analysis
# ============================================================================

# Get severity counts from critique
critique_get_issue_counts() {
    local critique="$1"

    echo "$critique" | jq '{
        blocker: [.issues_found // [] | .[] | select(.severity == "blocker")] | length,
        high: [.issues_found // [] | .[] | select(.severity == "high")] | length,
        medium: [.issues_found // [] | .[] | select(.severity == "medium")] | length,
        low: [.issues_found // [] | .[] | select(.severity == "low")] | length,
        total: [.issues_found // [] | .[]] | length
    }'
}

# Calculate adjusted confidence based on critique
critique_adjusted_confidence() {
    local critique="$1"
    local base_confidence="$2"

    local adjustment=$(echo "$critique" | jq -r '.confidence_adjustment // 0')
    local issue_counts=$(critique_get_issue_counts "$critique")

    # Penalize for issues
    local blocker_penalty=$(echo "$issue_counts" | jq -r '.blocker * 0.3')
    local high_penalty=$(echo "$issue_counts" | jq -r '.high * 0.1')
    local medium_penalty=$(echo "$issue_counts" | jq -r '.medium * 0.05')

    # Calculate final confidence (minimum 0, maximum 1)
    local final=$(echo "$base_confidence + $adjustment - $blocker_penalty - $high_penalty - $medium_penalty" | bc -l 2>/dev/null || echo "$base_confidence")

    # Clamp to [0, 1]
    if (( $(echo "$final < 0" | bc -l 2>/dev/null || echo "0") )); then
        final="0"
    elif (( $(echo "$final > 1" | bc -l 2>/dev/null || echo "0") )); then
        final="1"
    fi

    printf "%.2f" "$final"
}

# ============================================================================
# Critique Logging & Memory
# ============================================================================

# Log critique to events
critique_log() {
    local agent="$1"
    local critique="$2"

    if [ -z "$critique" ]; then
        return
    fi

    local passed=$(echo "$critique" | jq -r '.critique_passed // false')
    local ready=$(echo "$critique" | jq -r '.ready_to_submit // false')
    local issue_counts=$(critique_get_issue_counts "$critique")

    if type log_event &>/dev/null; then
        log_event "agent_critique" "$(jq -cn \
            --arg agent "$agent" \
            --argjson passed "$passed" \
            --argjson ready "$ready" \
            --argjson issue_counts "$issue_counts" \
            '{agent: $agent, critique_passed: $passed, ready_to_submit: $ready} + $issue_counts'
        )"
    fi
}

# Record critique to agent memory for learning
critique_record_to_memory() {
    local agent="$1"
    local critique="$2"
    local final_success="$3"

    if [ -z "$critique" ]; then
        return
    fi

    # If agent_memory_record_critique exists (added in agent_memory.sh), call it
    if type agent_memory_record_critique &>/dev/null; then
        agent_memory_record_critique "$agent" "$critique" "$final_success"
    fi
}

# ============================================================================
# Critique Prompt Generation
# ============================================================================

# Generate critique phase instructions for agent prompt
critique_generate_prompt_section() {
    local agent="$1"
    local checklist=$(critique_get_checklist "$agent")

    cat <<EOF

## Before Finalizing: Self-Critique

Before outputting your HIVE_REPORT, perform a self-review:

**Checklist:**
$(echo "$checklist" | jq -r '.[] | "- [ ] \(.check)"')

**Output your critique as:**
\`\`\`
<!--HIVE_CRITIQUE
{
  "critique_passed": true,
  "checks_completed": ["list", "of", "passed", "check", "ids"],
  "checks_failed": [],
  "issues_found": [],
  "confidence_adjustment": 0,
  "ready_to_submit": true
}
HIVE_CRITIQUE-->
\`\`\`

If you find issues:
- Set \`critique_passed\` to false
- List failed checks in \`checks_failed\`
- Document issues in \`issues_found\` with severity (blocker/high/medium/low) and whether fixable
- Set \`ready_to_submit\` to false if you need to make changes
- If fixable, make the changes before outputting HIVE_REPORT

EOF
}
