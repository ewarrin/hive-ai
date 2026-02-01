#!/usr/bin/env bash
# Hive Self-Eval - Agent self-assessment parsing
#
# Agents output a structured HIVE_REPORT block at the end of their work.
# The orchestrator reads this directly instead of relying on external validation.
#
# NEW: Agents can also output HIVE_CRITIQUE for self-reflection before HIVE_REPORT.
#
# Format agents should output:
#
#   <!--HIVE_CRITIQUE
#   {
#     "critique_passed": true,
#     "checks_completed": ["builds", "tests_pass"],
#     "checks_failed": [],
#     "issues_found": [],
#     "confidence_adjustment": 0,
#     "ready_to_submit": true
#   }
#   HIVE_CRITIQUE-->
#
#   <!--HIVE_REPORT
#   {
#     "status": "complete|partial|blocked",
#     "confidence": 0.0-1.0,
#     "tasks_created": ["bd-abc", "bd-def"],
#     "tasks_closed": ["bd-ghi"],
#     "files_modified": ["src/app.vue", "nuxt.config.ts"],
#     "decisions": [{"decision": "Use pnpm", "rationale": "Template requires it"}],
#     "blockers": [],
#     "summary": "Created 6 tasks for Nuxt dashboard deployment",
#     "next_agent_hint": "implementer"
#   }
#   HIVE_REPORT-->

HIVE_DIR="${HIVE_DIR:-.hive}"

# ============================================================================
# Parse Critique from Agent Output
# ============================================================================

# Extract HIVE_CRITIQUE JSON from agent output file
# Returns the JSON block or empty string if not found
selfeval_extract_critique() {
    local output_file="$1"

    if [ ! -f "$output_file" ]; then
        echo ""
        return 1
    fi

    # Extract content between <!--HIVE_CRITIQUE and HIVE_CRITIQUE-->
    local critique=$(sed -n '/<!--HIVE_CRITIQUE/,/HIVE_CRITIQUE-->/p' "$output_file" \
        | sed '1d;$d' \
        | tr -d '\r')

    # Validate it's actual JSON
    if [ -n "$critique" ] && echo "$critique" | jq empty 2>/dev/null; then
        echo "$critique"
        return 0
    fi

    # Try alternate format: ```hive_critique ... ```
    critique=$(sed -n '/```hive_critique/,/```/p' "$output_file" \
        | sed '1d;$d' \
        | tr -d '\r')

    if [ -n "$critique" ] && echo "$critique" | jq empty 2>/dev/null; then
        echo "$critique"
        return 0
    fi

    echo ""
    return 1
}

# Check if agent output contains a critique
selfeval_has_critique() {
    local output_file="$1"

    if [ ! -f "$output_file" ]; then
        return 1
    fi

    grep -q "HIVE_CRITIQUE" "$output_file"
}

# ============================================================================
# Parse Self-Eval from Agent Output
# ============================================================================

# Extract HIVE_REPORT JSON from agent output file
# Returns the JSON block or empty string if not found
selfeval_extract() {
    local output_file="$1"
    
    if [ ! -f "$output_file" ]; then
        echo ""
        return 1
    fi
    
    # Extract content between <!--HIVE_REPORT and HIVE_REPORT-->
    local report=$(sed -n '/<!--HIVE_REPORT/,/HIVE_REPORT-->/p' "$output_file" \
        | sed '1d;$d' \
        | tr -d '\r')
    
    # Validate it's actual JSON
    if [ -n "$report" ] && echo "$report" | jq empty 2>/dev/null; then
        echo "$report"
        return 0
    fi
    
    # Try alternate format: ```hive_report ... ```
    report=$(sed -n '/```hive_report/,/```/p' "$output_file" \
        | sed '1d;$d' \
        | tr -d '\r')
    
    if [ -n "$report" ] && echo "$report" | jq empty 2>/dev/null; then
        echo "$report"
        return 0
    fi
    
    # Try raw JSON block with "status" and "confidence" keys
    report=$(grep -A 50 '"status"' "$output_file" 2>/dev/null \
        | head -50 \
        | python3 -c "
import sys, json
text = sys.stdin.read()
# Find first complete JSON object
depth = 0
start = -1
for i, c in enumerate(text):
    if c == '{':
        if depth == 0: start = i
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0 and start >= 0:
            try:
                obj = json.loads(text[start:i+1])
                if 'status' in obj and 'confidence' in obj:
                    print(json.dumps(obj))
                    sys.exit(0)
            except: pass
sys.exit(1)
" 2>/dev/null)
    
    if [ -n "$report" ] && echo "$report" | jq empty 2>/dev/null; then
        echo "$report"
        return 0
    fi
    
    echo ""
    return 1
}

# Validate a self-eval report has required fields
selfeval_validate() {
    local report="$1"
    
    if [ -z "$report" ]; then
        echo '{"valid": false, "reason": "No report found"}'
        return 1
    fi
    
    local has_status=$(echo "$report" | jq 'has("status")')
    local has_confidence=$(echo "$report" | jq 'has("confidence")')
    local has_summary=$(echo "$report" | jq 'has("summary")')
    
    if [ "$has_status" == "true" ] && [ "$has_confidence" == "true" ] && [ "$has_summary" == "true" ]; then
        echo '{"valid": true}'
        return 0
    fi
    
    local missing="[]"
    [ "$has_status" != "true" ] && missing=$(echo "$missing" | jq '. += ["status"]')
    [ "$has_confidence" != "true" ] && missing=$(echo "$missing" | jq '. += ["confidence"]')
    [ "$has_summary" != "true" ] && missing=$(echo "$missing" | jq '. += ["summary"]')
    
    jq -n --argjson missing "$missing" '{"valid": false, "reason": "Missing fields", "missing": $missing}'
    return 1
}

# Determine if agent succeeded based on self-eval
selfeval_passed() {
    local report="$1"
    local agent="$2"
    
    if [ -z "$report" ]; then
        # No self-eval - fall back to legacy validation
        echo "no_report"
        return 2
    fi
    
    local status=$(echo "$report" | jq -r '.status // "unknown"')
    local confidence=$(echo "$report" | jq -r '.confidence // 0')
    
    case "$status" in
        "complete")
            # High confidence = pass, low confidence = warn but pass
            if (( $(echo "$confidence >= 0.7" | bc -l 2>/dev/null || echo "1") )); then
                echo "pass"
                return 0
            else
                echo "pass_low_confidence"
                return 0
            fi
            ;;
        "partial")
            # Check if blockers exist
            local blocker_count=$(echo "$report" | jq '[.blockers // [] | .[] | select(. != null and . != "")] | length')
            if [ "$blocker_count" -gt 0 ]; then
                echo "blocked"
                return 1
            fi
            echo "partial"
            return 0
            ;;
        "blocked")
            echo "blocked"
            return 1
            ;;
        *)
            echo "unknown_status"
            return 2
            ;;
    esac
}

# Get the structured data from self-eval for scratchpad/handoff updates
selfeval_get_field() {
    local report="$1"
    local field="$2"
    
    echo "$report" | jq -r ".$field // empty"
}

selfeval_get_array() {
    local report="$1"
    local field="$2"
    
    echo "$report" | jq ".$field // []"
}

# Apply self-eval data to scratchpad
selfeval_apply_to_scratchpad() {
    local report="$1"
    
    if [ -z "$report" ]; then
        return 1
    fi
    
    # Add decisions (handles both string array and object array formats)
    local decisions=$(echo "$report" | jq -c '.decisions // []')
    if [ "$decisions" != "[]" ]; then
        local agent=$(echo "$report" | jq -r '.agent // "unknown"')
        echo "$decisions" | jq -c '.[]' | while read -r decision; do
            local d=""
            local r=""
            # Check if it's a string or an object
            local dtype=$(echo "$decision" | jq -r 'type' 2>/dev/null)
            if [ "$dtype" == "string" ]; then
                d=$(echo "$decision" | jq -r '.')
                r=""
            elif [ "$dtype" == "object" ]; then
                d=$(echo "$decision" | jq -r '.decision // empty')
                r=$(echo "$decision" | jq -r '.rationale // ""')
            fi
            if [ -n "$d" ]; then
                scratchpad_add_decision "$agent" "$d" "$r"
            fi
        done
    fi
    
    # Add files to context
    local files=$(echo "$report" | jq -c '.files_modified // []')
    if [ "$files" != "[]" ]; then
        echo "$files" | jq -r '.[]' | while read -r file; do
            scratchpad_add_key_file "$file"
        done
    fi
    
    # Add blockers
    local blockers=$(echo "$report" | jq -c '.blockers // []')
    if [ "$blockers" != "[]" ]; then
        echo "$blockers" | jq -r '.[]' | while read -r blocker; do
            if [ -n "$blocker" ]; then
                local agent=$(echo "$report" | jq -r '.agent // "unknown"')
                scratchpad_add_blocker "$agent" "$blocker"
            fi
        done
    fi
}

# Log self-eval to events
selfeval_log() {
    local agent="$1"
    local report="$2"

    if [ -z "$report" ]; then
        return
    fi

    local status=$(echo "$report" | jq -r '.status // "unknown"')
    local confidence=$(echo "$report" | jq -r '.confidence // 0')
    local summary=$(echo "$report" | jq -r '.summary // ""')
    local tasks_created=$(echo "$report" | jq '.tasks_created // [] | length')
    local tasks_closed=$(echo "$report" | jq '.tasks_closed // [] | length')
    local files_modified=$(echo "$report" | jq '.files_modified // [] | length')

    if type log_event &>/dev/null; then
        log_event "agent_selfeval" "$(jq -cn \
            --arg agent "$agent" \
            --arg status "$status" \
            --arg confidence "$confidence" \
            --arg summary "$summary" \
            --argjson tasks_created "$tasks_created" \
            --argjson tasks_closed "$tasks_closed" \
            --argjson files_modified "$files_modified" \
            '{agent: $agent, status: $status, confidence: ($confidence | tonumber), summary: $summary, tasks_created: $tasks_created, tasks_closed: $tasks_closed, files_modified: $files_modified}'
        )"
    fi
}

# ============================================================================
# Combined Critique + Report Processing
# ============================================================================

# Extract both critique and report from agent output
# Returns JSON with both blocks
selfeval_extract_all() {
    local output_file="$1"

    local critique=$(selfeval_extract_critique "$output_file")
    local report=$(selfeval_extract "$output_file")

    jq -cn \
        --argjson critique "$(echo "${critique:-null}" | jq '.')" \
        --argjson report "$(echo "${report:-null}" | jq '.')" \
        '{
            has_critique: ($critique != null),
            has_report: ($report != null),
            critique: $critique,
            report: $report
        }'
}

# Determine overall result considering both critique and report
# Returns: pass, pass_with_warnings, needs_revision, blocked, no_report
selfeval_overall_result() {
    local output_file="$1"
    local agent="$2"

    local all=$(selfeval_extract_all "$output_file")
    local has_critique=$(echo "$all" | jq -r '.has_critique')
    local has_report=$(echo "$all" | jq -r '.has_report')

    if [ "$has_report" != "true" ]; then
        echo "no_report"
        return 2
    fi

    local report=$(echo "$all" | jq '.report')
    local report_result=$(selfeval_passed "$report" "$agent")

    # If no critique, use report result directly
    if [ "$has_critique" != "true" ]; then
        echo "$report_result"
        return $?
    fi

    # Check critique
    local critique=$(echo "$all" | jq '.critique')
    local critique_passed=$(echo "$critique" | jq -r '.critique_passed // true')
    local ready_to_submit=$(echo "$critique" | jq -r '.ready_to_submit // true')

    # If critique says not ready, needs revision
    if [ "$critique_passed" == "false" ] || [ "$ready_to_submit" == "false" ]; then
        echo "needs_revision"
        return 1
    fi

    # Check for issues found
    local issue_count=$(echo "$critique" | jq '[.issues_found // [] | .[]] | length')
    if [ "$issue_count" -gt 0 ]; then
        # Has issues but marked as ready - pass with warnings
        if [ "$report_result" == "pass" ]; then
            echo "pass_with_warnings"
            return 0
        fi
    fi

    echo "$report_result"
    return $?
}
