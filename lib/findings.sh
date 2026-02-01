#!/usr/bin/env bash
# Hive Findings - Structured code review findings management
#
# Parses reviewer output, creates Beads tickets, provides triage UI

# ============================================================================
# Configuration
# ============================================================================

HIVE_DIR="${HIVE_DIR:-.hive}"

# Cross-platform timestamp
_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Colors
_F_RED='\033[0;31m'
_F_GREEN='\033[0;32m'
_F_YELLOW='\033[1;33m'
_F_BLUE='\033[0;34m'
_F_CYAN='\033[0;36m'
_F_MAGENTA='\033[0;35m'
_F_BOLD='\033[1m'
_F_DIM='\033[2m'
_F_NC='\033[0m'

# Box drawing
_F_BOX_TL='╭'
_F_BOX_TR='╮'
_F_BOX_BL='╰'
_F_BOX_BR='╯'
_F_BOX_H='─'
_F_BOX_V='│'
_F_BOX_VR='├'
_F_BOX_VL='┤'

# ============================================================================
# Finding Storage
# ============================================================================

_findings_file() {
    local run_id="${1:-current}"
    echo "$HIVE_DIR/runs/$run_id/findings.json"
}

findings_init() {
    local run_id="$1"
    local findings_file=$(_findings_file "$run_id")
    
    mkdir -p "$(dirname "$findings_file")"
    
    cat > "$findings_file" << 'EOF'
{
  "findings": [],
  "summary": {
    "blocker": 0,
    "high": 0,
    "medium": 0,
    "low": 0,
    "total": 0
  },
  "created_at": null,
  "triaged": false
}
EOF
    
    # Update timestamp
    local tmp=$(mktemp)
    jq --arg ts "$(_timestamp)" '.created_at = $ts' "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
}

# ============================================================================
# Parse Findings from Reviewer Output
# ============================================================================

# Extract findings from HIVE_REPORT in reviewer output
findings_parse_from_output() {
    local output_file="$1"
    local run_id="$2"
    local epic_id="$3"
    
    if [ ! -f "$output_file" ]; then
        echo "[]"
        return
    fi
    
    # Extract HIVE_REPORT JSON
    local report=$(sed -n '/<!--HIVE_REPORT/,/HIVE_REPORT-->/p' "$output_file" | sed '1d;$d')
    
    if [ -z "$report" ] || ! echo "$report" | jq . >/dev/null 2>&1; then
        echo "[]"
        return
    fi
    
    # Extract issues array
    local issues=$(echo "$report" | jq -r '.issues // .findings // .issues_found // []')
    
    if [ "$issues" = "null" ] || [ "$issues" = "[]" ]; then
        echo "[]"
        return
    fi
    
    echo "$issues"
}

# Create Beads tickets from findings
findings_create_tickets() {
    local findings_json="$1"
    local epic_id="$2"
    local run_id="$3"
    
    local findings_file=$(_findings_file "$run_id")
    findings_init "$run_id"
    
    local count=0
    local blocker=0
    local high=0
    local medium=0
    local low=0
    
    # Process each finding
    echo "$findings_json" | jq -c '.[]' 2>/dev/null | while read -r finding; do
        local title=$(echo "$finding" | jq -r '.title // .message // "Review finding"')
        local severity=$(echo "$finding" | jq -r '.severity // "medium"' | tr '[:upper:]' '[:lower:]')
        local category=$(echo "$finding" | jq -r '.category // .type // "general"')
        local file=$(echo "$finding" | jq -r '.file // .location // ""')
        local line=$(echo "$finding" | jq -r '.line // .line_number // ""')
        local description=$(echo "$finding" | jq -r '.description // .details // ""')
        local suggestion=$(echo "$finding" | jq -r '.suggestion // .fix // .recommended_fix // ""')
        local code=$(echo "$finding" | jq -r '.code // .snippet // ""')
        
        # Normalize severity
        case "$severity" in
            critical|blocker) severity="blocker" ;;
            high|major) severity="high" ;;
            medium|moderate|normal) severity="medium" ;;
            low|minor|trivial|style) severity="low" ;;
            *) severity="medium" ;;
        esac
        
        # Build title with location
        local full_title="Review: $title"
        [ -n "$file" ] && full_title="$full_title [$file"
        [ -n "$line" ] && full_title="$full_title:$line"
        [ -n "$file" ] && full_title="$full_title]"
        
        # Truncate title if too long
        [ ${#full_title} -gt 80 ] && full_title="${full_title:0:77}..."
        
        # Build notes
        local notes=""
        [ -n "$description" ] && notes="$description"
        [ -n "$code" ] && notes="$notes

\`\`\`
$code
\`\`\`"
        [ -n "$suggestion" ] && notes="$notes

**Suggested fix:** $suggestion"
        
        # Create Beads ticket
        local ticket_id=""
        if command -v bd &>/dev/null; then
            ticket_id=$(bd create "$full_title" --parent "$epic_id" 2>/dev/null | grep -oE 'bd-[a-z0-9]+' | head -1)
            
            if [ -n "$ticket_id" ] && [ -n "$notes" ]; then
                bd note "$ticket_id" "$notes" 2>/dev/null || true
            fi
        fi
        
        # Store finding with ticket ID
        local tmp=$(mktemp)
        jq --arg id "${ticket_id:-untracked-$count}" \
           --arg title "$title" \
           --arg severity "$severity" \
           --arg category "$category" \
           --arg file "$file" \
           --arg line "$line" \
           --arg description "$description" \
           --arg suggestion "$suggestion" \
           --arg status "open" \
           '.findings += [{
             id: $id,
             title: $title,
             severity: $severity,
             category: $category,
             file: $file,
             line: ($line | if . == "" then null else tonumber end),
             description: $description,
             suggestion: $suggestion,
             status: $status
           }]' "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
        
        count=$((count + 1))
    done
    
    # Update summary counts
    local tmp=$(mktemp)
    jq '.summary.blocker = ([.findings[] | select(.severity == "blocker")] | length) |
        .summary.high = ([.findings[] | select(.severity == "high")] | length) |
        .summary.medium = ([.findings[] | select(.severity == "medium")] | length) |
        .summary.low = ([.findings[] | select(.severity == "low")] | length) |
        .summary.total = (.findings | length)' "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
    
    # Return count
    jq -r '.summary.total' "$findings_file"
}

# ============================================================================
# Triage UI
# ============================================================================

findings_triage_ui() {
    local run_id="$1"
    local epic_id="$2"
    
    local findings_file=$(_findings_file "$run_id")
    
    if [ ! -f "$findings_file" ]; then
        echo "No findings to triage."
        return 0
    fi
    
    local data=$(cat "$findings_file")
    local total=$(echo "$data" | jq -r '.summary.total')
    
    if [ "$total" -eq 0 ]; then
        echo ""
        echo -e "${_F_GREEN}✓${_F_NC} No issues found by reviewer!"
        echo ""
        return 0
    fi
    
    while true; do
        clear
        _findings_display "$findings_file"
        
        # Check if all triaged
        local open_count=$(jq '[.findings[] | select(.status == "open")] | length' "$findings_file")
        local blocker_count=$(jq '[.findings[] | select(.severity == "blocker" and .status == "open")] | length' "$findings_file")
        local high_count=$(jq '[.findings[] | select(.severity == "high" and .status == "open")] | length' "$findings_file")
        
        echo ""
        echo -e "${_F_BOLD}Actions:${_F_NC}"
        echo -e "  ${_F_CYAN}[F]${_F_NC} Fix blockers/high automatically"
        echo -e "  ${_F_CYAN}[V]${_F_NC} View finding details"
        echo -e "  ${_F_CYAN}[A]${_F_NC} Accept risk (mark as won't fix)"
        echo -e "  ${_F_CYAN}[D]${_F_NC} Defer to later"
        echo -e "  ${_F_CYAN}[C]${_F_NC} Continue to next phase"
        echo -e "  ${_F_CYAN}[Q]${_F_NC} Quit workflow"
        echo ""
        
        # Warning if blockers exist
        if [ "$blocker_count" -gt 0 ]; then
            echo -e "${_F_RED}⚠ $blocker_count blocker(s) must be addressed before continuing${_F_NC}"
            echo ""
        fi
        
        read -p "> " -n 1 -r action < /dev/tty
        echo ""
        
        case "${action,,}" in
            f)
                _findings_fix_interactive "$findings_file" "$epic_id"
                ;;
            v)
                _findings_view_detail "$findings_file"
                ;;
            a)
                _findings_accept_risk "$findings_file"
                ;;
            d)
                _findings_defer "$findings_file"
                ;;
            c)
                if [ "$blocker_count" -gt 0 ]; then
                    echo ""
                    echo -e "${_F_RED}Cannot continue with $blocker_count open blocker(s).${_F_NC}"
                    echo "Fix or accept risk first."
                    read -p "Press Enter to continue..." < /dev/tty
                else
                    # Mark as triaged
                    local tmp=$(mktemp)
                    jq '.triaged = true' "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
                    return 0
                fi
                ;;
            q)
                return 1
                ;;
            *)
                ;;
        esac
    done
}

_findings_display() {
    local findings_file="$1"
    local data=$(cat "$findings_file")
    
    local blocker=$(echo "$data" | jq -r '.summary.blocker')
    local high=$(echo "$data" | jq -r '.summary.high')
    local medium=$(echo "$data" | jq -r '.summary.medium')
    local low=$(echo "$data" | jq -r '.summary.low')
    local total=$(echo "$data" | jq -r '.summary.total')
    
    # Header
    echo ""
    printf "${_F_CYAN}${_F_BOX_TL}${_F_BOX_H} Code Review Findings "
    printf "${_F_BOX_H}%.0s" {1..32}
    printf "${_F_BOX_TR}${_F_NC}\n"
    
    printf "${_F_CYAN}${_F_BOX_V}${_F_NC}%53s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
    
    # Blockers
    if [ "$blocker" -gt 0 ]; then
        printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_RED}🔴 Blocker ($blocker)${_F_NC}%$((35 - ${#blocker}))s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
        echo "$data" | jq -r '.findings[] | select(.severity == "blocker" and .status == "open") | "\(.id)|\(.title)|\(.file)|\(.line)"' | head -5 | while IFS='|' read -r id title file line; do
            local display_title="${title:0:35}"
            printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_BOX_VR}${_F_BOX_H} ${_F_DIM}[$id]${_F_NC} $display_title%$((18 - ${#display_title}))s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
            if [ -n "$file" ]; then
                local loc="$file"
                [ -n "$line" ] && loc="$loc:$line"
                loc="${loc:0:40}"
                printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_BOX_V}   ${_F_DIM}$loc${_F_NC}%$((45 - ${#loc}))s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
            fi
        done
        printf "${_F_CYAN}${_F_BOX_V}${_F_NC}%53s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
    fi
    
    # High
    if [ "$high" -gt 0 ]; then
        printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_YELLOW}🟠 High ($high)${_F_NC}%$((39 - ${#high}))s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
        echo "$data" | jq -r '.findings[] | select(.severity == "high" and .status == "open") | "\(.id)|\(.title)|\(.file)"' | head -3 | while IFS='|' read -r id title file; do
            local display_title="${title:0:35}"
            printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_BOX_VR}${_F_BOX_H} ${_F_DIM}[$id]${_F_NC} $display_title%$((18 - ${#display_title}))s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
        done
        [ "$high" -gt 3 ] && printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_DIM}   ... and $((high - 3)) more${_F_NC}%30s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
        printf "${_F_CYAN}${_F_BOX_V}${_F_NC}%53s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
    fi
    
    # Medium
    if [ "$medium" -gt 0 ]; then
        local open_medium=$(echo "$data" | jq '[.findings[] | select(.severity == "medium" and .status == "open")] | length')
        printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_BLUE}🟡 Medium ($medium)${_F_NC}%$((37 - ${#medium}))s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
        if [ "$open_medium" -gt 0 ]; then
            printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_DIM}   $open_medium open (view with: hive findings list)${_F_NC}%2s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
        fi
        printf "${_F_CYAN}${_F_BOX_V}${_F_NC}%53s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
    fi
    
    # Low
    if [ "$low" -gt 0 ]; then
        local open_low=$(echo "$data" | jq '[.findings[] | select(.severity == "low" and .status == "open")] | length')
        printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_DIM}⚪ Low ($low)${_F_NC}%$((41 - ${#low}))s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
        if [ "$open_low" -gt 0 ]; then
            printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_DIM}   $open_low open${_F_NC}%38s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
        fi
        printf "${_F_CYAN}${_F_BOX_V}${_F_NC}%53s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
    fi
    
    # Summary line
    local open_total=$(echo "$data" | jq '[.findings[] | select(.status == "open")] | length')
    local fixed=$(echo "$data" | jq '[.findings[] | select(.status == "fixed")] | length')
    local accepted=$(echo "$data" | jq '[.findings[] | select(.status == "accepted")] | length')
    
    printf "${_F_CYAN}${_F_BOX_VR}"
    printf "${_F_BOX_H}%.0s" {1..53}
    printf "${_F_BOX_VL}${_F_NC}\n"
    
    printf "${_F_CYAN}${_F_BOX_V}${_F_NC}  ${_F_DIM}Total: $total${_F_NC}  "
    [ "$open_total" -gt 0 ] && printf "${_F_YELLOW}○${_F_NC} $open_total open  "
    [ "$fixed" -gt 0 ] && printf "${_F_GREEN}✓${_F_NC} $fixed fixed  "
    [ "$accepted" -gt 0 ] && printf "${_F_BLUE}~${_F_NC} $accepted accepted"
    printf "%10s${_F_CYAN}${_F_BOX_V}${_F_NC}\n" ""
    
    printf "${_F_CYAN}${_F_BOX_BL}"
    printf "${_F_BOX_H}%.0s" {1..53}
    printf "${_F_BOX_BR}${_F_NC}\n"
}

_findings_view_detail() {
    local findings_file="$1"
    
    echo ""
    read -p "Enter finding ID (e.g., bd-a1b2): " finding_id < /dev/tty
    
    local finding=$(jq --arg id "$finding_id" '.findings[] | select(.id == $id)' "$findings_file")
    
    if [ -z "$finding" ] || [ "$finding" = "null" ]; then
        echo -e "${_F_RED}Finding not found: $finding_id${_F_NC}"
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    echo ""
    echo -e "${_F_BOLD}$(echo "$finding" | jq -r '.title')${_F_NC}"
    echo -e "${_F_DIM}────────────────────────────────────────${_F_NC}"
    echo ""
    
    local severity=$(echo "$finding" | jq -r '.severity')
    local category=$(echo "$finding" | jq -r '.category')
    local file=$(echo "$finding" | jq -r '.file // "—"')
    local line=$(echo "$finding" | jq -r '.line // "—"')
    local status=$(echo "$finding" | jq -r '.status')
    
    case "$severity" in
        blocker) echo -e "  ${_F_RED}Severity:${_F_NC} BLOCKER" ;;
        high) echo -e "  ${_F_YELLOW}Severity:${_F_NC} High" ;;
        medium) echo -e "  ${_F_BLUE}Severity:${_F_NC} Medium" ;;
        low) echo -e "  ${_F_DIM}Severity:${_F_NC} Low" ;;
    esac
    
    echo -e "  ${_F_DIM}Category:${_F_NC} $category"
    echo -e "  ${_F_DIM}Location:${_F_NC} $file:$line"
    echo -e "  ${_F_DIM}Status:${_F_NC}   $status"
    echo ""
    
    local description=$(echo "$finding" | jq -r '.description // ""')
    if [ -n "$description" ] && [ "$description" != "null" ]; then
        echo -e "${_F_BOLD}Description:${_F_NC}"
        echo "$description" | fold -s -w 60 | sed 's/^/  /'
        echo ""
    fi
    
    local suggestion=$(echo "$finding" | jq -r '.suggestion // ""')
    if [ -n "$suggestion" ] && [ "$suggestion" != "null" ]; then
        echo -e "${_F_BOLD}Suggested Fix:${_F_NC}"
        echo -e "  ${_F_GREEN}$suggestion${_F_NC}"
        echo ""
    fi
    
    # Show file context if available
    if [ -f "$file" ] && [ "$line" != "—" ] && [ "$line" != "null" ]; then
        echo -e "${_F_BOLD}Code Context:${_F_NC}"
        local start=$((line - 3))
        [ $start -lt 1 ] && start=1
        local end=$((line + 3))
        sed -n "${start},${end}p" "$file" 2>/dev/null | while IFS= read -r code_line; do
            if [ $start -eq $line ]; then
                echo -e "  ${_F_RED}→ $start: $code_line${_F_NC}"
            else
                echo -e "  ${_F_DIM}  $start: $code_line${_F_NC}"
            fi
            start=$((start + 1))
        done
        echo ""
    fi
    
    read -p "Press Enter to continue..." < /dev/tty
}

_findings_fix_interactive() {
    local findings_file="$1"
    local epic_id="$2"
    
    # Get blockers and high severity open findings
    local to_fix=$(jq -r '.findings[] | select((.severity == "blocker" or .severity == "high") and .status == "open") | .id' "$findings_file")
    
    if [ -z "$to_fix" ]; then
        echo ""
        echo -e "${_F_GREEN}No blocker/high severity issues to fix!${_F_NC}"
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    echo ""
    echo -e "${_F_BOLD}Fixing blocker/high severity issues...${_F_NC}"
    echo ""
    
    # Create a fix task in Beads
    local fix_task_id=""
    if command -v bd &>/dev/null; then
        fix_task_id=$(bd create "Fix critical review findings" --parent "$epic_id" 2>/dev/null | grep -oE 'bd-[a-z0-9]+' | head -1)
    fi
    
    echo "The following issues need to be fixed:"
    echo ""
    
    for finding_id in $to_fix; do
        local finding=$(jq --arg id "$finding_id" '.findings[] | select(.id == $id)' "$findings_file")
        local title=$(echo "$finding" | jq -r '.title')
        local file=$(echo "$finding" | jq -r '.file // "unknown"')
        local suggestion=$(echo "$finding" | jq -r '.suggestion // ""')
        
        echo -e "  ${_F_YELLOW}•${_F_NC} $title"
        echo -e "    ${_F_DIM}$file${_F_NC}"
        [ -n "$suggestion" ] && [ "$suggestion" != "null" ] && echo -e "    ${_F_GREEN}→ $suggestion${_F_NC}"
        echo ""
    done
    
    echo -e "${_F_DIM}────────────────────────────────────────${_F_NC}"
    echo ""
    echo "Options:"
    echo -e "  ${_F_CYAN}[A]${_F_NC} Auto-fix with AI (runs implementer agent)"
    echo -e "  ${_F_CYAN}[M]${_F_NC} Mark as fixed manually (I'll fix it myself)"
    echo -e "  ${_F_CYAN}[B]${_F_NC} Back to triage"
    echo ""
    
    read -p "> " -n 1 -r choice < /dev/tty
    echo ""
    
    case "${choice,,}" in
        a)
            echo ""
            echo -e "${_F_CYAN}Launching implementer to fix issues...${_F_NC}"
            echo ""
            
            # Build fix prompt
            local fix_prompt="Fix the following code review findings:\n\n"
            for finding_id in $to_fix; do
                local finding=$(jq --arg id "$finding_id" '.findings[] | select(.id == $id)' "$findings_file")
                local title=$(echo "$finding" | jq -r '.title')
                local file=$(echo "$finding" | jq -r '.file // ""')
                local line=$(echo "$finding" | jq -r '.line // ""')
                local description=$(echo "$finding" | jq -r '.description // ""')
                local suggestion=$(echo "$finding" | jq -r '.suggestion // ""')
                
                fix_prompt="$fix_prompt- $title\n"
                [ -n "$file" ] && fix_prompt="$fix_prompt  File: $file"
                [ -n "$line" ] && fix_prompt="$fix_prompt:$line"
                fix_prompt="$fix_prompt\n"
                [ -n "$description" ] && fix_prompt="$fix_prompt  Issue: $description\n"
                [ -n "$suggestion" ] && fix_prompt="$fix_prompt  Suggested fix: $suggestion\n"
                fix_prompt="$fix_prompt\n"
            done
            
            # Store prompt for implementer
            echo -e "$fix_prompt" > "$HIVE_DIR/fix_prompt.txt"
            
            echo "Fix prompt saved. Run implementer with:"
            echo -e "  ${_F_CYAN}hive run --only implementer \"Fix review findings\"${_F_NC}"
            echo ""
            
            # Mark as in-progress
            for finding_id in $to_fix; do
                local tmp=$(mktemp)
                jq --arg id "$finding_id" '(.findings[] | select(.id == $id)).status = "in_progress"' "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
            done
            
            read -p "Press Enter to continue..." < /dev/tty
            ;;
        m)
            echo ""
            echo "Marking issues as fixed..."
            
            for finding_id in $to_fix; do
                local tmp=$(mktemp)
                jq --arg id "$finding_id" '(.findings[] | select(.id == $id)).status = "fixed"' "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
                
                # Close Beads ticket if exists
                if command -v bd &>/dev/null && [[ "$finding_id" == bd-* ]]; then
                    bd close "$finding_id" --reason "Manually fixed" 2>/dev/null || true
                fi
                
                echo -e "  ${_F_GREEN}✓${_F_NC} $finding_id marked as fixed"
            done
            
            echo ""
            read -p "Press Enter to continue..." < /dev/tty
            ;;
        b)
            return
            ;;
    esac
}

_findings_accept_risk() {
    local findings_file="$1"
    
    echo ""
    read -p "Enter finding ID to accept: " finding_id < /dev/tty
    
    local finding=$(jq --arg id "$finding_id" '.findings[] | select(.id == $id)' "$findings_file")
    
    if [ -z "$finding" ] || [ "$finding" = "null" ]; then
        echo -e "${_F_RED}Finding not found: $finding_id${_F_NC}"
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    local severity=$(echo "$finding" | jq -r '.severity')
    local title=$(echo "$finding" | jq -r '.title')
    
    echo ""
    echo -e "Accepting risk for: ${_F_BOLD}$title${_F_NC}"
    
    if [ "$severity" = "blocker" ]; then
        echo -e "${_F_RED}⚠ This is a BLOCKER issue. Are you sure?${_F_NC}"
    fi
    
    echo ""
    read -p "Reason for accepting: " reason < /dev/tty
    
    if [ -z "$reason" ]; then
        echo "Reason required."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    # Update finding status
    local tmp=$(mktemp)
    jq --arg id "$finding_id" --arg reason "$reason" \
       '(.findings[] | select(.id == $id)) |= . + {status: "accepted", accept_reason: $reason}' \
       "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
    
    # Update Beads ticket
    if command -v bd &>/dev/null && [[ "$finding_id" == bd-* ]]; then
        bd note "$finding_id" "Accepted risk: $reason" 2>/dev/null || true
        bd close "$finding_id" --reason "Risk accepted: $reason" 2>/dev/null || true
    fi
    
    echo -e "${_F_GREEN}✓${_F_NC} Marked as accepted: $finding_id"
    read -p "Press Enter to continue..." < /dev/tty
}

_findings_defer() {
    local findings_file="$1"
    
    echo ""
    read -p "Enter finding ID to defer: " finding_id < /dev/tty
    
    local finding=$(jq --arg id "$finding_id" '.findings[] | select(.id == $id)' "$findings_file")
    
    if [ -z "$finding" ] || [ "$finding" = "null" ]; then
        echo -e "${_F_RED}Finding not found: $finding_id${_F_NC}"
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    local severity=$(echo "$finding" | jq -r '.severity')
    
    if [ "$severity" = "blocker" ]; then
        echo -e "${_F_RED}Cannot defer blocker issues.${_F_NC}"
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    # Update finding status
    local tmp=$(mktemp)
    jq --arg id "$finding_id" '(.findings[] | select(.id == $id)).status = "deferred"' \
       "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
    
    echo -e "${_F_GREEN}✓${_F_NC} Deferred: $finding_id"
    read -p "Press Enter to continue..." < /dev/tty
}

# ============================================================================
# CLI Integration
# ============================================================================

# Process reviewer output and launch triage
findings_process_and_triage() {
    local output_file="$1"
    local run_id="$2"
    local epic_id="$3"
    
    echo ""
    echo -e "${_F_DIM}Processing review findings...${_F_NC}"
    
    # Parse findings from output
    local findings_json=$(findings_parse_from_output "$output_file" "$run_id" "$epic_id")
    
    if [ "$findings_json" = "[]" ]; then
        echo -e "${_F_GREEN}✓${_F_NC} No issues found by reviewer!"
        return 0
    fi
    
    # Create tickets
    local count=$(findings_create_tickets "$findings_json" "$epic_id" "$run_id")
    
    echo -e "${_F_CYAN}Found $count issue(s) to review.${_F_NC}"
    
    # Launch triage UI
    if [ "${HIVE_AUTO_MODE:-0}" != "1" ]; then
        findings_triage_ui "$run_id" "$epic_id"
        return $?
    else
        echo -e "${_F_DIM}Auto mode: skipping triage UI${_F_NC}"
        
        # In auto mode, fail if blockers exist
        local blockers=$(jq '[.findings[] | select(.severity == "blocker")] | length' "$(_findings_file "$run_id")")
        if [ "$blockers" -gt 0 ]; then
            echo -e "${_F_RED}$blockers blocker(s) found. Stopping.${_F_NC}"
            return 1
        fi
        
        return 0
    fi
}
