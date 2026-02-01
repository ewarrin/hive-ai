#!/usr/bin/env bash
# Hive Workflows - Predefined workflow templates
#
# Built-in workflows:
#   feature  - Full pipeline: architect → implement → test → review
#   bugfix   - Skip architect: debugger → test → done
#   refactor - Architect → implement → test (no UI review)
#   test     - Just testing: tester → done
#   review   - Just review: reviewer → done
#   quick    - Minimal: implement → done
#
# Custom workflows live in .hive/workflows/ or ~/.hive/workflows/

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"

# ============================================================================
# Built-in Workflow Definitions
# ============================================================================

# Returns a workflow definition as JSON
workflow_get() {
    local name="${1:-feature}"
    
    # Check custom workflows first
    local custom_path="$HIVE_DIR/workflows/${name}.json"
    local global_path="$HIVE_ROOT/workflows/${name}.json"
    
    if [ -f "$custom_path" ]; then
        cat "$custom_path"
        return 0
    fi
    
    if [ -f "$global_path" ]; then
        cat "$global_path"
        return 0
    fi
    
    # Built-in workflows
    case "$name" in
        "feature"|"default")
            cat <<'EOF'
{
  "name": "feature",
  "description": "Full feature pipeline with all phases",
  "phases": [
    {
      "name": "interview",
      "type": "interview",
      "required": false
    },
    {
      "name": "design",
      "agent": "architect",
      "required": true,
      "human_checkpoint_after": true,
      "task": "Design the solution.\n\nAfter analyzing, create tasks in Beads:\n  bd create \"Task description\" --parent {{EPIC_ID}} -p 2\n\nCreate tasks for all work needed."
    },
    {
      "name": "implementation",
      "agent": "implementer",
      "required": true,
      "needs_handoff_from": "architect",
      "task": "Implement the designed solution.\n\n1. Run bd ready to see tasks\n2. Work on highest priority task\n3. Update Beads status as you work\n4. Close tasks when complete"
    },
    {
      "name": "build_check",
      "type": "build_verify",
      "required": true,
      "on_failure": "debugger"
    },
    {
      "name": "ui_review",
      "agent": "ui-designer",
      "required": false,
      "condition": "has_frontend",
      "needs_handoff_from": "implementer",
      "task": "Review and improve the UI quality.\n\nFocus on:\n- Design system consistency\n- Spacing, typography, color\n- Responsive design\n- Loading/empty/error states\n- Dark mode"
    },
    {
      "name": "testing",
      "agent": "tester",
      "required": true,
      "needs_handoff_from": "implementer",
      "task": "Write and run tests for the implementation.\n\n1. Bootstrap test infrastructure if needed (Vitest + Playwright)\n2. Write unit tests for new functions/utilities\n3. Write integration tests for component interactions\n4. Run all tests and report results\n5. File bugs for failures"
    },
    {
      "name": "e2e_testing",
      "agent": "e2e-tester",
      "required": true,
      "needs_handoff_from": "tester",
      "task": "Write and run Playwright e2e tests.\n\n1. Set up Playwright with browser if not present\n2. Write e2e tests for critical user flows\n3. Run tests with visible browser (--headed) to verify\n4. Report results with screenshots"
    },
    {
      "name": "browser_validation",
      "agent": "browser-validator",
      "required": true,
      "condition": "has_frontend",
      "needs_handoff_from": "e2e-tester",
      "task": "Visually validate the implementation in a real browser.\n\n1. Start dev server if not running\n2. Navigate through the new feature in a real browser\n3. Capture screenshots at key points\n4. Report any visual or functional issues"
    },
    {
      "name": "review",
      "agent": "reviewer",
      "required": false,
      "task": "Review all the changes made.\n\nFile issues found:\n- BLOCKING: bd create \"BLOCKING: ...\" -t bug -p 0 --parent {{EPIC_ID}}\n- IMPORTANT: bd create \"IMPORTANT: ...\" -t bug -p 1 --parent {{EPIC_ID}}\n- NITPICK: bd create \"NITPICK: ...\" -p 3 --parent {{EPIC_ID}}"
    },
    {
      "name": "documentation",
      "agent": "documenter",
      "required": false,
      "needs_handoff_from": "implementer",
      "task": "Document the new functionality.\n\n1. Add JSDoc/TSDoc to new functions\n2. Update README if user-facing\n3. Add API documentation if applicable\n4. Document any gotchas or important notes"
    },
    {
      "name": "fix_blockers",
      "type": "fix_blocking",
      "required": false
    }
  ]
}
EOF
            ;;
        
        "bugfix")
            cat <<'EOF'
{
  "name": "bugfix",
  "description": "Bug fix pipeline - skip architect, go straight to debugger",
  "phases": [
    {
      "name": "debug",
      "agent": "debugger",
      "required": true,
      "task": "Diagnose and fix the reported issue.\n\n1. Reproduce the problem\n2. Find root cause\n3. Implement the fix\n4. Verify it works\n5. Close the task in Beads"
    },
    {
      "name": "build_check",
      "type": "build_verify",
      "required": true,
      "on_failure": "debugger"
    },
    {
      "name": "testing",
      "agent": "tester",
      "required": true,
      "task": "Verify the fix and add regression tests.\n\n1. Write a test that would have caught this bug\n2. Verify the fix passes\n3. Run all existing tests\n4. Report results"
    },
    {
      "name": "e2e_testing",
      "agent": "e2e-tester",
      "required": true,
      "needs_handoff_from": "tester",
      "task": "Write e2e regression test for the bug fix.\n\n1. Write an e2e test that reproduces the original bug scenario\n2. Verify the test passes with the fix\n3. Run with --headed to visually confirm"
    },
    {
      "name": "browser_validation",
      "agent": "browser-validator",
      "required": false,
      "condition": "has_frontend",
      "needs_handoff_from": "e2e-tester",
      "task": "Visually verify the bug is fixed.\n\n1. Navigate to the affected area\n2. Confirm the bug no longer occurs\n3. Capture before/after screenshots if possible"
    }
  ]
}
EOF
            ;;
        
        "refactor")
            cat <<'EOF'
{
  "name": "refactor",
  "description": "Refactoring pipeline - architect plans, implement, test",
  "phases": [
    {
      "name": "design",
      "agent": "architect",
      "required": true,
      "human_checkpoint_after": true,
      "task": "Plan the refactoring.\n\nAnalyze the current code structure and design the refactoring approach.\nCreate tasks in Beads for each refactoring step.\nEnsure backwards compatibility."
    },
    {
      "name": "implementation",
      "agent": "implementer",
      "required": true,
      "needs_handoff_from": "architect",
      "task": "Execute the refactoring plan.\n\n1. Follow the architect's plan\n2. Make changes incrementally\n3. Keep existing tests passing\n4. Update Beads status as you work"
    },
    {
      "name": "build_check",
      "type": "build_verify",
      "required": true,
      "on_failure": "debugger"
    },
    {
      "name": "testing",
      "agent": "tester",
      "required": true,
      "task": "Verify refactoring didn't break anything.\n\n1. Run all existing tests\n2. Add tests for any new interfaces\n3. Check for regressions\n4. Report results"
    },
    {
      "name": "review",
      "agent": "reviewer",
      "required": false,
      "task": "Review the refactoring.\n\nFocus on:\n- Code quality improvement\n- API compatibility\n- Performance implications\n- Missing test coverage"
    }
  ]
}
EOF
            ;;
        
        "test")
            cat <<'EOF'
{
  "name": "test",
  "description": "Testing only - write and run tests",
  "phases": [
    {
      "name": "testing",
      "agent": "tester",
      "required": true,
      "task": "Write comprehensive tests.\n\n1. Analyze the codebase\n2. Identify untested paths\n3. Write unit tests\n4. Write integration tests\n5. Run and report results"
    }
  ]
}
EOF
            ;;
        
        "review")
            cat <<'EOF'
{
  "name": "review",
  "description": "Code review only",
  "phases": [
    {
      "name": "review",
      "agent": "reviewer",
      "required": true,
      "task": "Perform a thorough code review.\n\nReview recent changes and file issues:\n- BLOCKING: Critical issues\n- IMPORTANT: Should fix\n- NITPICK: Style/preference"
    }
  ]
}
EOF
            ;;
        
        "quick")
            cat <<'EOF'
{
  "name": "quick",
  "description": "Quick implementation - just implement, no review or tests",
  "phases": [
    {
      "name": "implementation",
      "agent": "implementer",
      "required": true,
      "task": "Implement the requested change.\n\n1. Understand the objective\n2. Make the changes\n3. Verify it works\n4. Update Beads"
    },
    {
      "name": "build_check",
      "type": "build_verify",
      "required": true,
      "on_failure": "debugger"
    }
  ]
}
EOF
            ;;
        
        "docs")
            cat <<'EOF'
{
  "name": "docs",
  "description": "Documentation workflow - analyze and document",
  "phases": [
    {
      "name": "documentation",
      "agent": "documenter",
      "required": true,
      "task": "Create or update documentation.\n\n1. Analyze the codebase\n2. Identify what needs documenting\n3. Write clear, useful documentation\n4. Update README if needed\n5. Add code comments where helpful"
    },
    {
      "name": "review",
      "agent": "reviewer",
      "required": false,
      "task": "Review the documentation changes.\n\nCheck for:\n- Accuracy\n- Clarity\n- Completeness\n- Formatting consistency"
    }
  ]
}
EOF
            ;;

        "migration")
            cat <<'EOF'
{
  "name": "migration",
  "description": "Database migration workflow - plan and execute schema changes",
  "phases": [
    {
      "name": "plan_migration",
      "agent": "migrator",
      "required": true,
      "human_checkpoint_after": true,
      "task": "Plan the database schema migration.\n\n1. Analyze the current schema\n2. Design the migration approach\n3. Generate migration files\n4. Create rollback script\n5. Document breaking changes"
    },
    {
      "name": "build_check",
      "type": "build_verify",
      "required": true,
      "on_failure": "debugger"
    },
    {
      "name": "testing",
      "agent": "tester",
      "required": false,
      "task": "Test the migration.\n\n1. Verify migration applies cleanly\n2. Test rollback works\n3. Check data integrity\n4. Verify application works with new schema"
    },
    {
      "name": "review",
      "agent": "reviewer",
      "required": false,
      "task": "Review the migration.\n\nCheck for:\n- Data safety (no accidental drops)\n- Rollback viability\n- Performance implications\n- Breaking changes documented"
    }
  ]
}
EOF
            ;;

        *)
            echo ""
            return 1
            ;;
    esac
}

# List all available workflows
workflow_list() {
    echo "Built-in workflows:"
    echo "  feature    Full pipeline: architect → implement → UI → test → e2e → browser → review → docs"
    echo "  bugfix     Bug fix: debugger → test → e2e → browser"
    echo "  refactor   Refactoring: architect → implement → test → review"
    echo "  test       Testing only: tester"
    echo "  review     Code review only: reviewer"
    echo "  quick      Minimal: implement → build check"
    echo "  docs       Documentation: documenter → review"
    echo "  migration  Database migration: migrator → test → review"
    
    # Check for custom workflows
    local has_custom=false
    
    if [ -d "$HIVE_DIR/workflows" ] && ls "$HIVE_DIR/workflows"/*.json &>/dev/null 2>&1; then
        echo ""
        echo "Project workflows:"
        for f in "$HIVE_DIR/workflows"/*.json; do
            local name=$(basename "$f" .json)
            local desc=$(jq -r '.description // ""' "$f")
            echo "  $name   $desc"
        done
        has_custom=true
    fi
    
    if [ -d "$HIVE_ROOT/workflows" ] && ls "$HIVE_ROOT/workflows"/*.json &>/dev/null 2>&1; then
        echo ""
        echo "Global workflows:"
        for f in "$HIVE_ROOT/workflows"/*.json; do
            local name=$(basename "$f" .json)
            local desc=$(jq -r '.description // ""' "$f")
            echo "  $name   $desc"
        done
        has_custom=true
    fi
}

# Get the phases for a workflow as a JSON array
workflow_phases() {
    local name="$1"
    local workflow=$(workflow_get "$name")
    
    if [ -z "$workflow" ]; then
        echo "[]"
        return 1
    fi
    
    echo "$workflow" | jq '.phases // []'
}

# Check if a workflow phase should run based on conditions
workflow_phase_should_run() {
    local phase_json="$1"
    local context_json="$2"
    
    local condition=$(echo "$phase_json" | jq -r '.condition // ""')
    
    if [ -z "$condition" ]; then
        # No condition - always run
        echo "true"
        return
    fi
    
    case "$condition" in
        "has_frontend")
            echo "$context_json" | jq -r '.has_frontend // false'
            ;;
        "has_tests")
            echo "$context_json" | jq -r '.has_tests // false'
            ;;
        *)
            # Unknown condition - run by default
            echo "true"
            ;;
    esac
}

# Get the display name for a workflow
workflow_display_phases() {
    local name="$1"
    local workflow=$(workflow_get "$name")
    
    if [ -z "$workflow" ]; then
        echo "unknown"
        return
    fi
    
    echo "$workflow" | jq -r '[.phases[] | select(.agent != null) | .agent] | join(" → ")'
}
