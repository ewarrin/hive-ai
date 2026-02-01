#!/usr/bin/env bash
# Hive Git Integration - Branch, commit, and PR automation
#
# Manages git workflow: branch creation, commits per phase, PR creation

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"

# Colors
_G_CYAN='\033[0;36m'
_G_GREEN='\033[0;32m'
_G_YELLOW='\033[1;33m'
_G_RED='\033[0;31m'
_G_DIM='\033[2m'
_G_BOLD='\033[1m'
_G_NC='\033[0m'

# ============================================================================
# Git State
# ============================================================================

_GIT_ORIGINAL_BRANCH=""
_GIT_WORK_BRANCH=""
_GIT_ENABLED=false

# ============================================================================
# Initialization
# ============================================================================

# Check if git is available and we're in a repo
git_is_available() {
    command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null
}

# Initialize git integration for a run
# Usage: git_init_run <objective> <run_id>
git_init_run() {
    local objective="$1"
    local run_id="$2"
    
    if ! git_is_available; then
        echo -e "${_G_DIM}Git not available, skipping git integration${_G_NC}"
        _GIT_ENABLED=false
        return 1
    fi
    
    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --staged --quiet; then
        echo -e "${_G_YELLOW}⚠${_G_NC} Uncommitted changes detected"
        echo -e "${_G_DIM}  Stashing changes before starting...${_G_NC}"
        git stash push -m "hive-pre-run-$run_id" || true
    fi
    
    # Store original branch
    _GIT_ORIGINAL_BRANCH=$(git branch --show-current)
    
    # Generate branch name from objective
    local branch_name=$(git_generate_branch_name "$objective" "$run_id")
    _GIT_WORK_BRANCH="$branch_name"
    
    # Create and checkout branch
    echo -e "${_G_CYAN}▶${_G_NC} Creating branch: ${_G_BOLD}$branch_name${_G_NC}"
    
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
        echo -e "${_G_YELLOW}  Branch exists, checking out${_G_NC}"
        git checkout "$branch_name"
    else
        git checkout -b "$branch_name"
    fi
    
    _GIT_ENABLED=true
    
    # Store git state
    git_save_state "$run_id"
    
    return 0
}

# Generate a clean branch name from objective
git_generate_branch_name() {
    local objective="$1"
    local run_id="$2"
    
    # Extract first few meaningful words
    local slug=$(echo "$objective" | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[^a-z0-9 ]//g' | \
        awk '{print $1"-"$2"-"$3}' | \
        sed 's/-$//' | \
        head -c 30)
    
    # Add prefix based on objective keywords
    local prefix="feature"
    if echo "$objective" | grep -qiE "fix|bug|error|crash|broken"; then
        prefix="fix"
    elif echo "$objective" | grep -qiE "refactor|clean|improve|optimize"; then
        prefix="refactor"
    elif echo "$objective" | grep -qiE "doc|readme|comment"; then
        prefix="docs"
    elif echo "$objective" | grep -qiE "test|spec|coverage"; then
        prefix="test"
    fi
    
    echo "hive/${prefix}/${slug}"
}

# Save git state for resume
git_save_state() {
    local run_id="$1"
    
    cat > "$HIVE_DIR/runs/$run_id/git_state.json" << EOF
{
  "original_branch": "$_GIT_ORIGINAL_BRANCH",
  "work_branch": "$_GIT_WORK_BRANCH",
  "enabled": $_GIT_ENABLED,
  "commits": []
}
EOF
}

# Load git state for resume
git_load_state() {
    local run_id="$1"
    local state_file="$HIVE_DIR/runs/$run_id/git_state.json"
    
    if [ -f "$state_file" ]; then
        _GIT_ORIGINAL_BRANCH=$(jq -r '.original_branch' "$state_file")
        _GIT_WORK_BRANCH=$(jq -r '.work_branch' "$state_file")
        _GIT_ENABLED=$(jq -r '.enabled' "$state_file")
        return 0
    fi
    return 1
}

# ============================================================================
# Commit Operations
# ============================================================================

# Commit changes after an agent completes
# Usage: git_commit_phase <agent> <summary> <run_id>
git_commit_phase() {
    local agent="$1"
    local summary="$2"
    local run_id="$3"
    
    if [ "$_GIT_ENABLED" != "true" ]; then
        return 0
    fi
    
    # Check if there are changes to commit
    if git diff --quiet && git diff --staged --quiet; then
        echo -e "${_G_DIM}  No changes to commit${_G_NC}"
        return 0
    fi
    
    # Stage all changes
    git add -A
    
    # Build commit message
    local commit_msg="[$agent] $summary

Run: $run_id
Agent: $agent

🐝 Automated commit by Hive"

    # Commit
    git commit -m "$commit_msg" --no-verify
    
    local commit_hash=$(git rev-parse --short HEAD)
    echo -e "${_G_GREEN}✓${_G_NC} Committed: ${_G_DIM}$commit_hash${_G_NC} [$agent] $summary"
    
    # Record commit
    local state_file="$HIVE_DIR/runs/$run_id/git_state.json"
    if [ -f "$state_file" ]; then
        local tmp=$(mktemp)
        jq --arg hash "$commit_hash" --arg agent "$agent" --arg msg "$summary" \
           '.commits += [{hash: $hash, agent: $agent, message: $msg, timestamp: now}]' \
           "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    fi
    
    return 0
}

# Commit with a custom message
git_commit() {
    local message="$1"
    local run_id="$2"
    
    if [ "$_GIT_ENABLED" != "true" ]; then
        return 0
    fi
    
    if git diff --quiet && git diff --staged --quiet; then
        return 0
    fi
    
    git add -A
    git commit -m "$message

🐝 Automated commit by Hive (run: $run_id)" --no-verify
    
    echo -e "${_G_GREEN}✓${_G_NC} Committed: $message"
}

# ============================================================================
# Branch Operations
# ============================================================================

# Get current work branch
git_get_branch() {
    echo "$_GIT_WORK_BRANCH"
}

# Get original branch
git_get_original_branch() {
    echo "$_GIT_ORIGINAL_BRANCH"
}

# Switch back to original branch
git_restore_branch() {
    if [ "$_GIT_ENABLED" != "true" ]; then
        return 0
    fi
    
    if [ -n "$_GIT_ORIGINAL_BRANCH" ]; then
        git checkout "$_GIT_ORIGINAL_BRANCH"
    fi
}

# Delete work branch (cleanup)
git_cleanup_branch() {
    if [ "$_GIT_ENABLED" != "true" ]; then
        return 0
    fi
    
    if [ -n "$_GIT_WORK_BRANCH" ] && [ "$_GIT_WORK_BRANCH" != "$_GIT_ORIGINAL_BRANCH" ]; then
        git checkout "$_GIT_ORIGINAL_BRANCH"
        git branch -D "$_GIT_WORK_BRANCH" 2>/dev/null || true
    fi
}

# ============================================================================
# Pull Request
# ============================================================================

# Create a pull request (GitHub CLI)
# Usage: git_create_pr <title> <body> <run_id>
git_create_pr() {
    local title="$1"
    local body="$2"
    local run_id="$3"
    
    if [ "$_GIT_ENABLED" != "true" ]; then
        echo "Git integration not enabled"
        return 1
    fi
    
    # Check for gh CLI
    if ! command -v gh &>/dev/null; then
        echo -e "${_G_YELLOW}GitHub CLI (gh) not installed${_G_NC}"
        echo -e "${_G_DIM}Install with: brew install gh${_G_NC}"
        echo ""
        echo "Manual PR creation:"
        echo "  Branch: $_GIT_WORK_BRANCH"
        echo "  Base: $_GIT_ORIGINAL_BRANCH"
        return 1
    fi
    
    # Check if authenticated
    if ! gh auth status &>/dev/null; then
        echo -e "${_G_YELLOW}GitHub CLI not authenticated${_G_NC}"
        echo -e "${_G_DIM}Run: gh auth login${_G_NC}"
        return 1
    fi
    
    # Push branch
    echo -e "${_G_CYAN}▶${_G_NC} Pushing branch..."
    git push -u origin "$_GIT_WORK_BRANCH"
    
    # Create PR
    echo -e "${_G_CYAN}▶${_G_NC} Creating pull request..."
    
    local pr_body="$body

---

## Hive Run Details

- **Run ID:** $run_id
- **Branch:** \`$_GIT_WORK_BRANCH\`

### Commits
$(git log --oneline "$_GIT_ORIGINAL_BRANCH..$_GIT_WORK_BRANCH" | sed 's/^/- /')

---
🐝 *Created by [Hive](https://github.com/anthropics/hive)*"

    local pr_url=$(gh pr create \
        --title "$title" \
        --body "$pr_body" \
        --base "$_GIT_ORIGINAL_BRANCH" \
        --head "$_GIT_WORK_BRANCH" \
        2>&1)
    
    if [ $? -eq 0 ]; then
        echo -e "${_G_GREEN}✓${_G_NC} Pull request created: $pr_url"
        
        # Store PR URL
        local state_file="$HIVE_DIR/runs/$run_id/git_state.json"
        if [ -f "$state_file" ]; then
            local tmp=$(mktemp)
            jq --arg url "$pr_url" '.pr_url = $url' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
        fi
        
        echo "$pr_url"
        return 0
    else
        echo -e "${_G_RED}✗${_G_NC} Failed to create PR: $pr_url"
        return 1
    fi
}

# Generate PR description from run
git_generate_pr_body() {
    local run_id="$1"
    local epic_id="$2"
    local objective="$3"
    
    local body="## Summary

$objective

## Changes

"
    
    # Add file changes
    local files_changed=$(git diff --name-only "$_GIT_ORIGINAL_BRANCH..$_GIT_WORK_BRANCH" 2>/dev/null | head -20)
    if [ -n "$files_changed" ]; then
        body+="### Files Changed

\`\`\`
$files_changed
\`\`\`

"
    fi
    
    # Add stats
    local stats=$(git diff --stat "$_GIT_ORIGINAL_BRANCH..$_GIT_WORK_BRANCH" 2>/dev/null | tail -1)
    if [ -n "$stats" ]; then
        body+="### Stats

$stats

"
    fi
    
    # Add Beads reference if available
    if [ -n "$epic_id" ]; then
        body+="## Related

- Epic: \`$epic_id\`
"
    fi
    
    echo "$body"
}

# ============================================================================
# Issue Integration
# ============================================================================

# Fetch issue details from GitHub
# Usage: git_fetch_issue <issue_number>
git_fetch_issue() {
    local issue="$1"
    
    if ! command -v gh &>/dev/null; then
        return 1
    fi
    
    gh issue view "$issue" --json title,body,labels,assignees 2>/dev/null
}

# Parse issue reference from objective
# Returns issue number if found
git_parse_issue_ref() {
    local objective="$1"
    
    # Match patterns like: #123, issue 123, issue #123, GH-123
    local issue=$(echo "$objective" | grep -oE '(#|issue |GH-)[0-9]+' | grep -oE '[0-9]+' | head -1)
    
    echo "$issue"
}

# Enrich objective with issue details
git_enrich_objective() {
    local objective="$1"
    
    local issue_num=$(git_parse_issue_ref "$objective")
    
    if [ -n "$issue_num" ]; then
        local issue_data=$(git_fetch_issue "$issue_num")
        
        if [ -n "$issue_data" ]; then
            local title=$(echo "$issue_data" | jq -r '.title')
            local body=$(echo "$issue_data" | jq -r '.body' | head -c 500)
            local labels=$(echo "$issue_data" | jq -r '.labels[].name' | tr '\n' ', ' | sed 's/,$//')
            
            echo "$objective

---
**Issue #$issue_num:** $title
**Labels:** $labels

$body"
            return 0
        fi
    fi
    
    echo "$objective"
}

# ============================================================================
# Workflow Completion
# ============================================================================

# Finalize git workflow - offer to create PR
git_finalize_run() {
    local run_id="$1"
    local epic_id="$2"
    local objective="$3"
    
    if [ "$_GIT_ENABLED" != "true" ]; then
        return 0
    fi
    
    # Check if there are commits
    local commit_count=$(git rev-list --count "$_GIT_ORIGINAL_BRANCH..$_GIT_WORK_BRANCH" 2>/dev/null || echo "0")
    
    if [ "$commit_count" -eq 0 ]; then
        echo -e "${_G_DIM}No commits on branch, skipping git finalize${_G_NC}"
        return 0
    fi
    
    echo ""
    echo -e "${_G_BOLD}Git Summary${_G_NC}"
    echo -e "${_G_DIM}───────────${_G_NC}"
    echo -e "  Branch: ${_G_CYAN}$_GIT_WORK_BRANCH${_G_NC}"
    echo -e "  Commits: $commit_count"
    echo ""
    
    # Show commits
    git log --oneline "$_GIT_ORIGINAL_BRANCH..$_GIT_WORK_BRANCH" | head -10 | while read line; do
        echo -e "  ${_G_DIM}$line${_G_NC}"
    done
    
    echo ""
    
    # Check if remote exists
    local has_remote=false
    if git remote get-url origin &>/dev/null; then
        has_remote=true
    fi
    
    if [ "$has_remote" = "false" ]; then
        echo -e "${_G_YELLOW}No remote 'origin' configured.${_G_NC}"
        echo -e "${_G_DIM}Add a remote with: git remote add origin <url>${_G_NC}"
        echo -e "${_G_DIM}Branch kept locally: $_GIT_WORK_BRANCH${_G_NC}"
        echo ""
        return 0
    fi
    
    # Offer options
    echo -e "${_G_CYAN}[P]${_G_NC} Push branch and create Pull Request"
    echo -e "${_G_CYAN}[U]${_G_NC} Push branch only (no PR)"
    echo -e "${_G_CYAN}[S]${_G_NC} Skip (keep local, don't push)"
    echo -e "${_G_CYAN}[D]${_G_NC} Delete branch and discard all changes"
    echo ""
    
    read -p "> " -n 1 -r choice < /dev/tty
    echo ""
    
    case "${choice,,}" in
        p)
            # Push and create PR
            echo ""
            echo -e "${_G_CYAN}▶${_G_NC} Pushing branch..."
            if ! git push -u origin "$_GIT_WORK_BRANCH" 2>&1; then
                echo -e "${_G_RED}Failed to push branch${_G_NC}"
                return 1
            fi
            echo -e "${_G_GREEN}✓${_G_NC} Branch pushed"
            
            # Create PR if gh available
            if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
                local title="$objective"
                [ ${#title} -gt 60 ] && title="${title:0:57}..."
                
                local body=$(git_generate_pr_body "$run_id" "$epic_id" "$objective")
                git_create_pr "$title" "$body" "$run_id"
            else
                echo ""
                echo -e "${_G_DIM}GitHub CLI not available for PR creation.${_G_NC}"
                echo -e "${_G_DIM}Create PR manually at your repository.${_G_NC}"
            fi
            ;;
        u)
            # Push only
            echo ""
            echo -e "${_G_CYAN}▶${_G_NC} Pushing branch..."
            if git push -u origin "$_GIT_WORK_BRANCH" 2>&1; then
                echo -e "${_G_GREEN}✓${_G_NC} Branch pushed: $_GIT_WORK_BRANCH"
                echo -e "${_G_DIM}Create PR manually when ready.${_G_NC}"
            else
                echo -e "${_G_RED}Failed to push branch${_G_NC}"
            fi
            ;;
        d)
            echo ""
            echo -e "${_G_YELLOW}Discarding changes and deleting branch...${_G_NC}"
            git checkout "$_GIT_ORIGINAL_BRANCH"
            git branch -D "$_GIT_WORK_BRANCH" 2>/dev/null || true
            echo -e "${_G_GREEN}✓${_G_NC} Branch deleted"
            ;;
        *)
            echo ""
            echo -e "${_G_DIM}Branch kept locally: $_GIT_WORK_BRANCH${_G_NC}"
            echo -e "${_G_DIM}Push later with: git push -u origin $_GIT_WORK_BRANCH${_G_NC}"
            ;;
    esac
}

# ============================================================================
# Utilities
# ============================================================================

# Get diff stats for display
git_get_diff_stats() {
    if [ "$_GIT_ENABLED" != "true" ]; then
        return
    fi
    
    git diff --stat "$_GIT_ORIGINAL_BRANCH..$_GIT_WORK_BRANCH" 2>/dev/null | tail -1
}

# Check if on work branch
git_on_work_branch() {
    [ "$(git branch --show-current)" = "$_GIT_WORK_BRANCH" ]
}
