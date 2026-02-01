#!/usr/bin/env bash
# Hive Router - Dynamic agent routing based on task analysis

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"

# ============================================================================
# Core Routing
# ============================================================================

# Determine which agent should handle a task
route_task() {
    local task_json="$1"
    
    local title=$(echo "$task_json" | jq -r '.title // .action // ""')
    local type=$(echo "$task_json" | jq -r '.type // ""')
    local file=$(echo "$task_json" | jq -r '.file // ""')
    
    # Route by explicit type first
    case "$type" in
        "bug"|"debug")
            echo "debugger"
            return
            ;;
        "test"|"testing")
            # Determine which tester
            if echo "$title" | grep -qiE "e2e|end.to.end|playwright|cypress|user journey"; then
                echo "e2e-tester"
            elif echo "$title" | grep -qiE "component|unit test|vitest"; then
                echo "component-tester"
            else
                echo "tester"
            fi
            return
            ;;
        "ui"|"design"|"ui_review")
            echo "ui-designer"
            return
            ;;
        "review"|"code review")
            echo "reviewer"
            return
            ;;
        "security"|"security_review"|"vulnerability")
            echo "security"
            return
            ;;
        "architecture"|"design"|"planning")
            echo "architect"
            return
            ;;
        "migration"|"database"|"schema")
            echo "migrator"
            return
            ;;
    esac
    
    # Route by file type
    if [ -n "$file" ]; then
        case "$file" in
            *.vue|*.tsx|*.jsx)
                # Frontend file - needs implementer, then possibly UI designer
                echo "implementer"
                return
                ;;
            *.spec.ts|*.test.ts|*.spec.js|*.test.js)
                echo "tester"
                return
                ;;
            *e2e*|*playwright*)
                echo "e2e-tester"
                return
                ;;
        esac
    fi
    
    # Route by title keywords
    local title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')
    
    # Bug/fix related
    if echo "$title_lower" | grep -qE "fix|bug|error|crash|broken|debug"; then
        echo "debugger"
        return
    fi
    
    # Testing related
    if echo "$title_lower" | grep -qE "test|spec|coverage"; then
        if echo "$title_lower" | grep -qE "e2e|end.to.end|integration|playwright"; then
            echo "e2e-tester"
        elif echo "$title_lower" | grep -qE "component|unit"; then
            echo "component-tester"
        else
            echo "tester"
        fi
        return
    fi
    
    # UI/design related
    if echo "$title_lower" | grep -qE "ui|ux|design|style|css|layout|responsive|dark mode|theme"; then
        echo "ui-designer"
        return
    fi
    
    # Review related
    if echo "$title_lower" | grep -qE "review|audit|check"; then
        echo "reviewer"
        return
    fi
    
    # Security related
    if echo "$title_lower" | grep -qE "security|vulnerability|vulnerabilities|injection|xss|csrf|auth bypass|penetration|owasp|cve"; then
        echo "security"
        return
    fi

    # Migration related
    if echo "$title_lower" | grep -qE "migration|migrate|schema|database schema|add column|drop column|alter table|create table|rollback|prisma|drizzle|alembic|knex"; then
        echo "migrator"
        return
    fi

    # Architecture related
    if echo "$title_lower" | grep -qE "architect|design|plan|structure|organize"; then
        echo "architect"
        return
    fi

    # Default to implementer
    echo "implementer"
}

# Route multiple tasks, grouping by agent
route_tasks() {
    local tasks_json="$1"
    
    local routing="{}"
    
    echo "$tasks_json" | jq -c '.[]' | while read -r task; do
        local agent=$(route_task "$task")
        local task_id=$(echo "$task" | jq -r '.beads_id // .task_id // .id // "unknown"')
        
        # This approach has issues with subshells, so we output JSON lines instead
        jq -n --arg agent "$agent" --arg task_id "$task_id" --argjson task "$task" \
            '{agent: $agent, task_id: $task_id, task: $task}'
    done
}

# Get next agent in the standard workflow
get_next_agent() {
    local current_agent="$1"
    local has_frontend="${2:-false}"
    local has_tests="${3:-true}"
    
    case "$current_agent" in
        "architect")
            echo "implementer"
            ;;
        "implementer")
            if [ "$has_frontend" == "true" ]; then
                echo "ui-designer"
            elif [ "$has_tests" == "true" ]; then
                echo "tester"
            else
                echo "reviewer"
            fi
            ;;
        "ui-designer")
            if [ "$has_tests" == "true" ]; then
                echo "tester"
            else
                echo "reviewer"
            fi
            ;;
        "tester"|"e2e-tester"|"component-tester")
            echo "reviewer"
            ;;
        "reviewer")
            echo "complete"
            ;;
        "debugger")
            # After debugging, go back to whatever was being done
            # This should be handled by the orchestrator based on context
            echo "retry_previous"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Determine if project has frontend components
detect_frontend() {
    # Check for frontend indicators
    if [ -f "nuxt.config.ts" ] || [ -f "nuxt.config.js" ]; then
        echo "true"
        return
    fi
    
    if [ -f "next.config.js" ] || [ -f "next.config.mjs" ]; then
        echo "true"
        return
    fi
    
    if [ -f "vite.config.ts" ] || [ -f "vite.config.js" ]; then
        echo "true"
        return
    fi
    
    if [ -d "app/pages" ] || [ -d "pages" ] || [ -d "src/pages" ]; then
        echo "true"
        return
    fi
    
    if [ -d "app/components" ] || [ -d "components" ] || [ -d "src/components" ]; then
        echo "true"
        return
    fi
    
    # Check for Vue/React files
    if find . -maxdepth 3 -name "*.vue" -o -name "*.tsx" -o -name "*.jsx" 2>/dev/null | head -1 | grep -q .; then
        echo "true"
        return
    fi
    
    echo "false"
}

# Determine the testing strategy
detect_test_strategy() {
    local strategy="{\"has_tests\": false, \"frameworks\": []}"
    
    local frameworks="[]"
    
    # Check for test frameworks
    if [ -f "package.json" ]; then
        if grep -q "vitest" package.json; then
            frameworks=$(echo "$frameworks" | jq '. += ["vitest"]')
        fi
        if grep -q "jest" package.json; then
            frameworks=$(echo "$frameworks" | jq '. += ["jest"]')
        fi
        if grep -q "playwright" package.json; then
            frameworks=$(echo "$frameworks" | jq '. += ["playwright"]')
        fi
        if grep -q "cypress" package.json; then
            frameworks=$(echo "$frameworks" | jq '. += ["cypress"]')
        fi
    fi
    
    # Check for test directories
    local has_tests="false"
    if [ -d "tests" ] || [ -d "test" ] || [ -d "__tests__" ] || [ -d "spec" ]; then
        has_tests="true"
    fi
    
    # Check for test files
    if find . -maxdepth 3 -name "*.spec.*" -o -name "*.test.*" 2>/dev/null | head -1 | grep -q .; then
        has_tests="true"
    fi
    
    jq -n \
        --argjson has_tests "$has_tests" \
        --argjson frameworks "$frameworks" \
        '{has_tests: $has_tests, frameworks: $frameworks}'
}

# ============================================================================
# Workflow Planning
# ============================================================================

# Plan the full workflow for an objective
plan_workflow() {
    local objective="$1"
    
    local has_frontend=$(detect_frontend)
    local test_strategy=$(detect_test_strategy)
    local has_tests=$(echo "$test_strategy" | jq -r '.has_tests')
    
    local workflow="[]"
    
    # Always start with architect
    workflow=$(echo "$workflow" | jq '. += [{"agent": "architect", "phase": "design"}]')
    
    # Implementation
    workflow=$(echo "$workflow" | jq '. += [{"agent": "implementer", "phase": "implementation"}]')
    
    # Build check (implicit, handled by orchestrator)
    
    # UI review if frontend
    if [ "$has_frontend" == "true" ]; then
        workflow=$(echo "$workflow" | jq '. += [{"agent": "ui-designer", "phase": "ui_review"}]')
    fi
    
    # Testing
    local test_frameworks=$(echo "$test_strategy" | jq -r '.frameworks')
    if echo "$test_frameworks" | jq -e 'contains(["playwright"])' &>/dev/null; then
        workflow=$(echo "$workflow" | jq '. += [{"agent": "e2e-tester", "phase": "testing"}]')
    fi
    workflow=$(echo "$workflow" | jq '. += [{"agent": "tester", "phase": "testing"}]')
    
    # Review
    workflow=$(echo "$workflow" | jq '. += [{"agent": "reviewer", "phase": "review"}]')
    
    jq -n \
        --argjson workflow "$workflow" \
        --argjson has_frontend "$has_frontend" \
        --argjson test_strategy "$test_strategy" \
        '{
            workflow: $workflow,
            has_frontend: $has_frontend,
            test_strategy: $test_strategy
        }'
}

# ============================================================================
# Dynamic Re-routing
# ============================================================================

# Route based on validation failure
route_on_failure() {
    local agent="$1"
    local error="$2"
    local validation_result="$3"
    
    # Check what kind of failure
    local error_lower=$(echo "$error" | tr '[:upper:]' '[:lower:]')
    
    # Build errors -> debugger
    if echo "$error_lower" | grep -qE "build|compile|syntax|parse|cannot find|undefined|type.*error"; then
        echo "debugger"
        return
    fi
    
    # Test failures -> debugger
    if echo "$error_lower" | grep -qE "test.*fail|assertion|expect"; then
        echo "debugger"
        return
    fi
    
    # Beads/contract failures -> retry same agent
    if echo "$error_lower" | grep -qE "beads|task.*not|contract"; then
        echo "retry"
        return
    fi
    
    # Default to retry
    echo "retry"
}

# Get agents that should run in parallel (if supported in future)
get_parallel_agents() {
    local phase="$1"
    
    case "$phase" in
        "testing")
            echo '["tester", "e2e-tester", "component-tester"]'
            ;;
        *)
            echo '[]'
            ;;
    esac
}
