#!/usr/bin/env bash
# Hive Smart Workflow Selection - Auto-select workflow based on objective
#
# Analyzes objectives to choose the right workflow and load relevant context

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"

# ============================================================================
# Workflow Classification (Bash 3 compatible)
# ============================================================================

# Get keywords for a workflow type
_workflow_keywords() {
    local workflow="$1"
    case "$workflow" in
        bugfix) echo "fix bug error crash broken issue problem fail failing debug wrong not working" ;;
        refactor) echo "refactor clean cleanup improve optimize reorganize restructure simplify extract rename" ;;
        test) echo "test spec coverage unit integration e2e testing tests" ;;
        review) echo "review audit check security scan analyze" ;;
        quick) echo "add simple small quick just only minor tweak change update" ;;
        docs) echo "document documentation readme doc comment jsdoc api docs" ;;
        feature) echo "create build implement add new feature develop make" ;;
        *) echo "" ;;
    esac
}

# Get priority for a workflow type (higher = more likely when ambiguous)
_workflow_priority() {
    local workflow="$1"
    case "$workflow" in
        bugfix) echo 90 ;;
        refactor) echo 80 ;;
        test) echo 70 ;;
        review) echo 60 ;;
        docs) echo 50 ;;
        quick) echo 40 ;;
        feature) echo 30 ;;
        *) echo 0 ;;
    esac
}

# ============================================================================
# Objective Analysis
# ============================================================================

# Analyze objective and return best workflow
# Usage: smart_select_workflow <objective>
smart_select_workflow() {
    local objective="$1"
    local objective_lower=$(echo "$objective" | tr '[:upper:]' '[:lower:]')
    
    local best_workflow="feature"
    local best_score=0
    
    # Score each workflow type
    for workflow in bugfix refactor test review quick docs feature; do
        local keywords=$(_workflow_keywords "$workflow")
        local score=0
        
        for keyword in $keywords; do
            if echo "$objective_lower" | grep -qw "$keyword"; then
                # Base score for match
                score=$((score + 10))
                
                # Bonus for keyword at start of objective
                if echo "$objective_lower" | grep -qE "^$keyword"; then
                    score=$((score + 20))
                fi
            fi
        done
        
        # Apply workflow priority
        local priority=$(_workflow_priority "$workflow")
        score=$((score + priority / 10))
        
        if [ $score -gt $best_score ]; then
            best_score=$score
            best_workflow=$workflow
        fi
    done
    
    # Special case: if objective is very short (< 5 words), prefer quick
    local word_count=$(echo "$objective" | wc -w)
    if [ $word_count -lt 5 ] && [ "$best_workflow" = "feature" ]; then
        best_workflow="quick"
    fi
    
    # Special case: issue reference → bugfix
    if echo "$objective" | grep -qE '(#[0-9]+|issue [0-9]+|bug [0-9]+|GH-[0-9]+)'; then
        best_workflow="bugfix"
    fi
    
    echo "$best_workflow"
}

# Get confidence in workflow selection (0-100)
smart_select_confidence() {
    local objective="$1"
    local workflow="$2"
    local objective_lower=$(echo "$objective" | tr '[:upper:]' '[:lower:]')
    
    local keywords=$(_workflow_keywords "$workflow")
    local matches=0
    local total=0
    
    for keyword in $keywords; do
        total=$((total + 1))
        if echo "$objective_lower" | grep -qw "$keyword"; then
            matches=$((matches + 1))
        fi
    done
    
    if [ $total -eq 0 ]; then
        echo "50"
        return
    fi
    
    # Base confidence on match ratio
    local confidence=$((matches * 100 / total))
    
    # Boost confidence if multiple matches
    if [ $matches -gt 2 ]; then
        confidence=$((confidence + 20))
    fi
    
    # Cap at 95
    [ $confidence -gt 95 ] && confidence=95
    
    echo "$confidence"
}

# Explain why a workflow was selected
smart_select_explain() {
    local objective="$1"
    local workflow="$2"
    local objective_lower=$(echo "$objective" | tr '[:upper:]' '[:lower:]')
    
    local keywords=$(_workflow_keywords "$workflow")
    local matched_keywords=""
    
    for keyword in $keywords; do
        if echo "$objective_lower" | grep -qw "$keyword"; then
            if [ -n "$matched_keywords" ]; then
                matched_keywords="$matched_keywords, $keyword"
            else
                matched_keywords="$keyword"
            fi
        fi
    done
    
    if [ -n "$matched_keywords" ]; then
        echo "Matched keywords: $matched_keywords"
    else
        echo "Default selection (no strong signals)"
    fi
}

# ============================================================================
# Context Loading
# ============================================================================

# Load relevant context based on objective
# Usage: smart_load_context <objective>
# Returns: Additional context to inject
smart_load_context() {
    local objective="$1"
    local objective_lower=$(echo "$objective" | tr '[:upper:]' '[:lower:]')
    local context=""
    
    # Detect areas of the codebase likely relevant
    local relevant_dirs=()
    
    # Auth-related
    if echo "$objective_lower" | grep -qE 'auth|login|logout|session|token|password|user|permission|role'; then
        relevant_dirs+=("src/auth" "src/middleware/auth" "lib/auth" "app/auth")
        context+="
## Likely Relevant: Authentication
This objective appears to involve authentication. Check:
- Auth middleware
- Session handling
- Token validation
- Permission checks
"
    fi
    
    # API-related
    if echo "$objective_lower" | grep -qE 'api|endpoint|route|rest|graphql|request|response'; then
        relevant_dirs+=("src/api" "src/routes" "app/api" "server/api" "pages/api")
        context+="
## Likely Relevant: API Layer
This objective appears to involve APIs. Check:
- Route handlers
- Request validation
- Response formatting
- Error handling
"
    fi
    
    # Database-related
    if echo "$objective_lower" | grep -qE 'database|db|query|table|schema|migration|model|entity'; then
        relevant_dirs+=("src/db" "src/models" "prisma" "drizzle" "migrations" "src/entities")
        context+="
## Likely Relevant: Database
This objective appears to involve the database. Check:
- Schema definitions
- Migration files
- Query patterns
- Transaction handling
"
    fi
    
    # UI-related
    if echo "$objective_lower" | grep -qE 'button|form|modal|page|component|style|css|ui|layout|design'; then
        relevant_dirs+=("src/components" "src/pages" "app/components" "components")
        context+="
## Likely Relevant: UI Components
This objective appears to involve UI. Check:
- Component patterns
- Style conventions
- State management
- Accessibility
"
    fi
    
    # Find actual files in relevant directories
    if [ ${#relevant_dirs[@]} -gt 0 ]; then
        local found_files=""
        for dir in "${relevant_dirs[@]}"; do
            if [ -d "$dir" ]; then
                local files=$(find "$dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.vue" -o -name "*.tsx" \) 2>/dev/null | head -5)
                if [ -n "$files" ]; then
                    found_files+="
### Files in $dir:
\`\`\`
$files
\`\`\`
"
                fi
            fi
        done
        
        if [ -n "$found_files" ]; then
            context+="
## Relevant Files Found
$found_files"
        fi
    fi
    
    # Check for issue reference and load it
    local issue_num=$(echo "$objective" | grep -oE '(#|issue |GH-)[0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -n "$issue_num" ] && command -v gh &>/dev/null; then
        local issue_data=$(gh issue view "$issue_num" --json title,body 2>/dev/null)
        if [ -n "$issue_data" ]; then
            local issue_title=$(echo "$issue_data" | jq -r '.title')
            local issue_body=$(echo "$issue_data" | jq -r '.body' | head -c 1000)
            context+="
## GitHub Issue #$issue_num

**Title:** $issue_title

**Description:**
$issue_body
"
        fi
    fi
    
    echo "$context"
}

# ============================================================================
# Git Blame Context
# ============================================================================

# Find who last touched relevant files
# Usage: smart_get_blame_context <objective>
smart_get_blame_context() {
    local objective="$1"
    local objective_lower=$(echo "$objective" | tr '[:upper:]' '[:lower:]')
    
    if ! command -v git &>/dev/null || ! git rev-parse --git-dir &>/dev/null; then
        return
    fi
    
    # Extract potential file/module names from objective
    local potential_files=$(echo "$objective" | grep -oE '[A-Za-z]+\.(ts|js|vue|tsx|jsx|py)' | head -3)
    local potential_paths=$(echo "$objective" | grep -oE 'src/[^ ]+|app/[^ ]+|lib/[^ ]+' | head -3)
    
    local blame_context=""
    
    for file in $potential_files $potential_paths; do
        # Find the actual file
        local found=$(find . -name "*$file*" -type f 2>/dev/null | grep -v node_modules | head -1)
        
        if [ -n "$found" ] && [ -f "$found" ]; then
            local last_author=$(git log -1 --format='%an' -- "$found" 2>/dev/null)
            local last_date=$(git log -1 --format='%ar' -- "$found" 2>/dev/null)
            
            if [ -n "$last_author" ]; then
                blame_context+="
- \`$found\`: Last modified by $last_author ($last_date)"
            fi
        fi
    done
    
    if [ -n "$blame_context" ]; then
        echo "
## Recent Changes
$blame_context
"
    fi
}

# ============================================================================
# Main Selection Function
# ============================================================================

# Full smart selection with context
# Usage: smart_analyze_objective <objective>
# Returns: JSON with workflow, confidence, context
smart_analyze_objective() {
    local objective="$1"
    
    local workflow=$(smart_select_workflow "$objective")
    local confidence=$(smart_select_confidence "$objective" "$workflow")
    local explanation=$(smart_select_explain "$objective" "$workflow")
    local context=$(smart_load_context "$objective")
    local blame=$(smart_get_blame_context "$objective")
    
    jq -n \
        --arg workflow "$workflow" \
        --argjson confidence "$confidence" \
        --arg explanation "$explanation" \
        --arg context "$context$blame" \
        '{
            workflow: $workflow,
            confidence: $confidence,
            explanation: $explanation,
            additional_context: $context
        }'
}

# ============================================================================
# Interactive Selection
# ============================================================================

# Suggest workflow with option to override
# Usage: smart_suggest_workflow <objective>
smart_suggest_workflow() {
    local objective="$1"
    
    local workflow=$(smart_select_workflow "$objective")
    local confidence=$(smart_select_confidence "$objective" "$workflow")
    local explanation=$(smart_select_explain "$objective" "$workflow")
    
    echo ""
    echo -e "\033[1mWorkflow Selection\033[0m"
    echo -e "\033[2m──────────────────\033[0m"
    echo ""
    echo -e "  Objective: \033[1m$objective\033[0m"
    echo ""
    echo -e "  Suggested: \033[36m$workflow\033[0m (${confidence}% confidence)"
    echo -e "  \033[2m$explanation\033[0m"
    echo ""
    
    if [ $confidence -lt 70 ]; then
        echo -e "\033[33m  Low confidence. Consider specifying workflow with -w\033[0m"
        echo ""
    fi
    
    # Return the workflow
    echo "$workflow"
}

# ============================================================================
# Workflow Descriptions
# ============================================================================

# Get description of a workflow
smart_workflow_description() {
    local workflow="$1"
    
    case "$workflow" in
        feature)
            echo "Full feature development: interview → architect → implement → test → review"
            ;;
        bugfix)
            echo "Bug fix workflow: debug → implement fix → test → verify"
            ;;
        refactor)
            echo "Code improvement: analyze → plan → refactor → test → review"
            ;;
        test)
            echo "Testing focus: analyze coverage → write tests → verify"
            ;;
        review)
            echo "Code review only: review → triage findings"
            ;;
        quick)
            echo "Quick change: minimal planning → implement → quick test"
            ;;
        docs)
            echo "Documentation: analyze → document → review"
            ;;
        *)
            echo "Unknown workflow"
            ;;
    esac
}
