# PLAN.md — Hive v4: From Automation to Intelligence

## Vision

Hive today is a sequential pipeline that runs agents in order. It's fancy automation.
Hive v4 is a system where agents think, challenge each other, learn from every run,
and get dramatically better over time. The 50th run on a project should feel like
working with a team that knows the codebase intimately — not a conveyor belt running
the same scripts.

This plan is informed by two frameworks:
- **Chris Lema's Four Levels of AI Work** — specifically the gaps at Level 2
  (compounding assets) and Level 4 (production-grade systems)
- **Boris Cherny's Claude Code tips** — parallel worktrees, plan-first, CLAUDE.md
  as living documentation, challenge-driven quality

## Architecture Principles

1. **Agents challenge, not just comply** — every handoff is a conversation, not a dump
2. **Knowledge compounds** — every run makes the next run better, concretely
3. **The orchestrator thinks** — routing decisions based on evidence, not hardcoded order
4. **Parallel by default** — independent work runs concurrently in worktrees
5. **Confidence is earned** — verified by checks and evaluation, not self-reported

---

## Phase 1: Challenge Handoffs

**Goal:** Agents critically review the previous agent's work before starting their own.
Quality comes from friction between agents, not from any single agent being perfect.

**The idea:** Each agent (except the first in the pipeline) gets a "Phase 0: Challenge"
added to its prompt. Before doing its work, it reads what it was handed and looks for
blocking problems. If it finds one, it reports a challenge instead of proceeding. The
orchestrator routes the challenge back to the challenged agent for resolution.

### Changes

**1.1 Update agent prompts**

Add a Phase 0 to each agent prompt (except architect, since it's first in the pipeline).
Each agent's challenge perspective is different:

- `agents/implementer.md` — Challenge the architect's plan:
  - Do referenced files/paths actually exist in the codebase?
  - Are tasks specific enough to implement without guessing?
  - Does existing code already solve part of this?
  - Are there contradictions between the plan and codebase reality?

- `agents/ui-designer.md` — Challenge architect/implementer:
  - Does the plan account for all UI states (empty, loading, error)?
  - Are component boundaries clear?
  - Do specified components match the framework's patterns?

- `agents/tester.md` — Challenge the implementer:
  - Does the implementation match what the architect planned?
  - Are there untested code paths or error handling gaps?
  - Did the implementer leave TODOs or incomplete work?

- `agents/reviewer.md` — Challenge everyone:
  - Does the implementation match the original objective?
  - Are there architectural decisions that contradict the plan?
  - Security or performance concerns nobody raised?

- `agents/documenter.md` — Challenge the reviewer:
  - Is the code self-documenting enough to describe?
  - Are there undocumented API changes or new interfaces?

- `agents/comb.md` — Challenge all incoming work:
  - Do the parallel changes contradict each other?
  - Is the merge order correct given dependencies?

The challenge prompt template for each agent:

```markdown
## Phase 0: Challenge the Handoff

Before starting your work, critically review what you were given.

Read the handoff context, the previous agent's output, and the current state of
the codebase. Ask yourself: can I succeed with what I've been given?

[Agent-specific challenge questions]

If you find a BLOCKING problem — something that will cause your work to fail or
produce wrong results — report it immediately. Do NOT proceed. Output a HIVE_REPORT:

<!--HIVE_REPORT
{
  "status": "challenge",
  "challenged_agent": "[agent name]",
  "issue": "Specific description of what's wrong",
  "evidence": "What you found — file paths, code snippets, contradictions",
  "suggestion": "How the challenged agent should fix this",
  "severity": "blocking"
}
HIVE_REPORT-->

Only challenge on blocking problems. Not style preferences. Not minor optimizations.
Not things you can work around. Real problems that will become bugs.

If no blocking problems, proceed to Phase 1.
```

**1.2 Update HIVE_REPORT status options**

In `lib/orchestrator.sh` around line 258-276, add "challenge" to the valid statuses:
```
Set status to: "complete", "partial", "blocked", or "challenge" (previous agent needs to fix something).
```

**1.3 Handle challenges in selfeval.sh**

In `selfeval_passed()`, add a case for "challenge" status that returns a distinct code:
```bash
"challenge")
    echo "challenge"
    return 3
    ;;
```

**1.4 Handle challenges in the orchestrator**

In `run_agent_with_validation()`, add a "challenge" branch alongside pass/partial/blocked.
When a challenge is detected:
1. Log the challenge event
2. Store the challenge details
3. Return exit code 2 (distinct from success=0 and failure=1)

In the workflow loop (`run_workflow()`), when an agent returns exit code 2:
1. Re-run the challenged agent with the challenge as additional context injected into prompt
2. Then re-run the challenging agent
3. Maximum 1 challenge loop per handoff — if it fails again, surface to human
4. Log all challenges in the event log

The challenged agent gets this injected into its context:
```markdown
## Challenge from [agent]

[agent] reviewed your work and found a blocking issue:

**Issue:** [description]
**Evidence:** [evidence]  
**Suggestion:** [suggestion]

Address this challenge and output a new HIVE_REPORT.
```

**1.5 Add challenge logging**

In `lib/logger.sh`, add:
```bash
log_challenge() {
    local from="$1" to="$2" issue="$3"
    log_event "challenge" "$from challenges $to: $issue"
}
```

### Files to modify
- `agents/implementer.md` — add Phase 0
- `agents/ui-designer.md` — add Phase 0
- `agents/tester.md` — add Phase 0
- `agents/reviewer.md` — add Phase 0
- `agents/documenter.md` — add Phase 0
- `agents/comb.md` — add Phase 0
- `lib/orchestrator.sh` — challenge handling in validation loop and workflow loop
- `lib/selfeval.sh` — recognize "challenge" status
- `lib/logger.sh` — log_challenge function

### Do NOT change
- Agent file structure (no new agent files)
- How `claude -p` is called
- The handoff.sh mechanism
- The TUI (it picks up events from the log naturally)

---

## Phase 2: Compounding Knowledge

**Goal:** Every run makes the next run better. Not just "remember the framework" but
"remember that the implementer struggles with auth patterns in this codebase, so inject
the auth middleware file into its context next time."

This is the Level 2 gap from Lema's framework. Hive has memory, but it doesn't compound.

### Changes

**2.1 Auto-update CLAUDE.md from agent learnings**

After every run, the orchestrator appends learnings to the project's CLAUDE.md. This is
the file Claude already reads on every invocation. Knowledge goes where it naturally flows.

At the end of `run_workflow()`, after the postmortem:

```bash
update_claude_md_from_run() {
    local run_id="$1"
    local learnings=""

    # Collect decisions from all agents
    local decisions=$(jq -r '.decisions[]? | "- \(.decision): \(.rationale)"' \
        "$HIVE_DIR/runs/$run_id/scratchpad_final.json" 2>/dev/null)

    # Collect gotchas from reviewer findings
    local findings=$(grep -h "BLOCKING\|IMPORTANT" \
        "$HIVE_DIR/runs/$run_id/output/reviewer_attempt_1.md" 2>/dev/null | head -5)

    # Collect patterns from implementer
    local patterns=$(jq -r '.concerns[]?' \
        "$HIVE_DIR/runs/$run_id/output/implementer_report.json" 2>/dev/null)

    # Only append if there's something new
    if [ -n "$decisions" ] || [ -n "$findings" ]; then
        echo "" >> CLAUDE.md
        echo "## Hive Learnings (Run $run_id)" >> CLAUDE.md
        echo "" >> CLAUDE.md
        [ -n "$decisions" ] && echo "$decisions" >> CLAUDE.md
        [ -n "$findings" ] && echo "$findings" >> CLAUDE.md
    fi
}
```

Over 10 runs, CLAUDE.md accumulates project-specific intelligence that every future
Claude session (not just Hive) benefits from.

**2.2 Agent-specific memory**

Extend `lib/memory.sh` to track per-agent performance patterns:

```json
{
  "agent_patterns": {
    "implementer": {
      "common_mistakes": ["forgets to update route index", "uses relative imports"],
      "files_it_struggles_with": ["server/middleware/auth.ts"],
      "avg_confidence": 0.82,
      "challenge_rate": 0.15
    },
    "architect": {
      "common_oversights": ["doesn't check existing components before designing new ones"],
      "avg_task_count": 4.5,
      "plans_that_needed_revision": 2
    }
  }
}
```

The orchestrator reads this before building each agent's prompt and injects relevant
warnings: "Note: In previous runs, you've forgotten to update the route index after
adding new pages. Check `app/routes.ts` when done."

**2.3 Context curation per agent**

Instead of dumping the same context to every agent, tailor it:

- **Architect gets:** Full codebase index, project memory, all previous decisions,
  constraints, CLAUDE.md. Maximum context for maximum reasoning.
- **Implementer gets:** Architect's plan, specific files to change (actual content,
  not just paths), test patterns to follow, its own mistake history.
- **Tester gets:** The diff only, implementer's handoff notes, test framework info.
  Minimal noise.
- **Reviewer gets:** The objective, the diff, architect's original plan, and the
  question "does the implementation match the intent?"

Modify the context-building section of `run_agent()` (around line 140-240 in
orchestrator.sh) to select context based on agent role.

**2.4 Portable agent skills**

Create a global agent directory that all projects inherit from:

```
~/.hive/global/agents/          # Shared across all projects
  architect.md
  implementer.md
  vue-implementer.md            # Specialized variant
  react-implementer.md
  ...

.hive/agents/                   # Project-level overrides
  implementer.md                # If present, overrides global
```

Resolution order in orchestrator: project `.hive/agents/` → global `~/.hive/global/agents/` → bundled `~/.hive/agents/`.

This lets you build specialized agents once (vue-implementer, api-implementer, etc.) and reuse across projects.

### Files to modify
- `lib/orchestrator.sh` — context curation, CLAUDE.md updates, agent resolution order
- `lib/memory.sh` — agent_patterns tracking, per-agent performance history
- `lib/postmortem.sh` — feed learnings to CLAUDE.md update function

### New files
- None (all changes are to existing files)

---

## Phase 3: Smart Orchestrator

**Goal:** The orchestrator stops being a for-loop and starts being a project manager.
It reads reports, makes routing decisions, and adapts the pipeline based on what's
actually happening.

### Changes

**3.1 Pre-run planning call**

Before running any agents, the orchestrator makes a lightweight LLM call (Haiku-level,
minimal tokens) to analyze the objective and decide the plan:

```bash
plan_pipeline() {
    local objective="$1"
    local codebase_index="$2"
    local project_memory="$3"

    local plan_prompt="Given this objective and codebase, which agents are needed
    and in what order? Not every task needs all agents.

    Objective: $objective
    Codebase: $codebase_index
    History: $project_memory

    Respond with JSON: {agents: ['architect', 'implementer', ...], reasoning: '...'}"

    # Use cheap/fast model for planning
    echo "$plan_prompt" | claude -p --model haiku
}
```

"Fix this typo" → just implementer.
"Redesign the auth system" → full pipeline with architect leading.
"Why is this test failing?" → tester in verify mode, maybe debugger.

**3.2 Between-agent evaluation**

After each agent completes, run three fast evaluator calls (Haiku-level) before
deciding what to do next. These replace the dumb "check confidence number" logic:

**Completeness evaluator:**
"List every noun and verb from the objective. Which are addressed in the output?
Which are missing?"

**Coherence evaluator:**
"Read this output as if you're the next agent. What questions would you need to
ask before starting?"

**Risk evaluator:**
"What's the most likely way this fails in production?"

Each returns a short verdict. The orchestrator combines them:

```
Completeness: ✓ all parts addressed
Coherence: ⚠ unclear how auth tokens refresh after upload
Risk: ⚠ no file size limit on uploads
```

Based on results:
- All clear → proceed to next agent
- Warnings → inject them as context for next agent
- Blocking gaps → retry current agent with specific feedback
- Multiple failures → surface to human with the three verdicts

**3.3 Evidence-based confidence**

Replace self-reported confidence with computed + evaluated confidence.

70% from automated checks (run after each agent, no LLM needed):
```bash
compute_confidence() {
    local agent="$1" output_file="$2"
    local score=0

    case "$agent" in
        architect)
            # Did it create beads tasks?
            local tasks=$(grep -c "bd create" "$output_file" 2>/dev/null)
            [ "$tasks" -gt 0 ] && score=$((score + 20))
            # Do tasks reference real file paths?
            local real_paths=$(grep -oE "src/[^ ]+" "$output_file" | while read p; do
                [ -e "$p" ] && echo 1; done | wc -l)
            [ "$real_paths" -gt 0 ] && score=$((score + 20))
            # No vague language?
            local vague=$(grep -ciE "maybe|could|possibly|might" "$output_file")
            [ "$vague" -lt 3 ] && score=$((score + 10))
            # Multiple approaches considered?
            grep -q "approach\|option\|alternative" "$output_file" && score=$((score + 10))
            # Has risks section?
            grep -q "risk\|edge case\|concern" "$output_file" && score=$((score + 10))
            ;;
        implementer)
            # Typecheck passes?
            npm run typecheck 2>/dev/null && score=$((score + 30))
            # Files changed match plan?
            local planned=$(jq -r '.files_modified[]?' "$HIVE_DIR/runs/$run_id/output/architect_report.json" 2>/dev/null | wc -l)
            local actual=$(git diff --name-only 2>/dev/null | wc -l)
            [ "$actual" -ge "$planned" ] && score=$((score + 20))
            # No TODOs left?
            local todos=$(grep -r "TODO\|FIXME\|HACK" --include="*.ts" --include="*.vue" 2>/dev/null | wc -l)
            [ "$todos" -eq 0 ] && score=$((score + 10))
            # Ran verification?
            grep -qE "tsc|eslint|npm run" "$output_file" && score=$((score + 10))
            ;;
        tester)
            # Tests actually ran?
            grep -qE "PASS|FAIL|✓|✗|tests?" "$output_file" && score=$((score + 30))
            # Pass rate?
            local passes=$(grep -c "✓\|PASS" "$output_file" 2>/dev/null)
            local fails=$(grep -c "✗\|FAIL" "$output_file" 2>/dev/null)
            [ "$passes" -gt 0 ] && [ "$fails" -eq 0 ] && score=$((score + 20))
            # Tested changed files?
            score=$((score + 10))  # Hard to verify automatically
            # No broken test files?
            score=$((score + 10))
            ;;
    esac

    echo "$score"  # Out of 70
}
```

30% from the evaluator calls (section 3.2 above).

Combined score determines routing, not the agent's self-assessment.

**3.4 Needs-input status**

Extend HIVE_REPORT to support `"status": "needs_input"`:

```json
{
  "status": "needs_input",
  "blocker": "Objective says 'match existing patterns' but auth uses REST and data uses GraphQL",
  "options": ["REST (matches auth)", "GraphQL (matches data)"],
  "can_proceed_with_default": true,
  "default_choice": "REST"
}
```

The orchestrator handles this:
- In auto mode: use the default choice, log it, proceed
- In interactive mode: surface the question to the human with options
- Store the decision in project memory for future reference

**3.5 Automatic bug-fix loops**

When the tester finds failures, automatically route back to the implementer:

```
tester finds 3 failing tests
  → orchestrator injects failure context into implementer prompt
  → implementer fixes
  → tester re-verifies
  → max 2 loops, then surface to human
```

This replaces the current behavior where test failures just get reported and the
pipeline continues.

### Files to modify
- `lib/orchestrator.sh` — planning call, evaluation calls, routing logic, fix loops
- `lib/selfeval.sh` — needs_input status, computed confidence
- `lib/workflow.sh` — dynamic pipeline from planner instead of static JSON

### New files
- `lib/evaluator.sh` — completeness/coherence/risk evaluation functions

---

## Phase 4: Parallel Worktrees

**Goal:** When the architect creates multiple independent tasks, run them in parallel
using git worktrees. Three implementers working simultaneously instead of one doing
everything serially.

### Changes

**4.1 Worktree-based parallel execution**

Replace the current branch-based parallelism in `lib/parallel.sh` with git worktrees:

```bash
# Create worktree for each parallel agent
parallel_create_worktree() {
    local task_id="$1"
    local worktree_dir=".hive/worktrees/$task_id"
    git worktree add "$worktree_dir" -b "hive/task/$task_id" 2>/dev/null
    echo "$worktree_dir"
}

# Run agent in isolated worktree
parallel_run_in_worktree() {
    local worktree="$1" agent="$2" task="$3"
    (
        cd "$worktree"
        # Run agent with task-specific context
        run_agent "$agent" "$task"
    )
}

# Clean up after merge
parallel_cleanup_worktree() {
    local task_id="$1"
    git worktree remove ".hive/worktrees/$task_id" 2>/dev/null
    git branch -d "hive/task/$task_id" 2>/dev/null
}
```

**4.2 Task dependency analysis**

After the architect creates tasks, analyze which can run in parallel:

```bash
analyze_parallelism() {
    local epic_id="$1"
    local tasks=$(bd list --json --parent "$epic_id")

    # Tasks with no blocked_by can run in parallel
    local independent=$(echo "$tasks" | jq '[.[] | select(.blocked_by == null or .blocked_by == [])]')
    local dependent=$(echo "$tasks" | jq '[.[] | select(.blocked_by != null and .blocked_by != [])]')

    echo "{\"parallel\": $independent, \"sequential\": $dependent}"
}
```

**4.3 Comb integration**

After parallel agents complete, automatically run the comb agent to weave their
worktrees together:

```
architect creates tasks A, B, C (independent) and D (depends on A+B)
  → worktree-A: implementer works on A
  → worktree-B: implementer works on B
  → worktree-C: implementer works on C
  → all complete → comb weaves A+B+C into main
  → implementer works on D (sequential, depends on merged result)
```

**4.4 TUI updates for parallel view**

The overview should show parallel agents side by side:

```
─ Pipeline ──────────────────────────────────
  ✓ architect
  ● implementer-A  ● implementer-B  ● implementer-C
  ○ comb
  ○ tester
  ○ reviewer
```

### Files to modify
- `lib/parallel.sh` — rewrite with worktree support
- `lib/orchestrator.sh` — detect parallelizable tasks, dispatch to worktrees
- `agents/comb.md` — update to handle worktree merges
- `bin/hive-status-tui` — parallel agent display

---

## Phase 5: Multi-Model Architecture

**Goal:** Use the best model for each job. Claude for thinking (architect, reviewer),
a cheaper/faster model for doing (implementer, documenter). This is Boris's
"plan-first" tip and Lema's two-model architecture applied to Hive.

### Changes

**5.1 Configurable backend per agent**

Add to `.hive/config.json`:

```json
{
  "models": {
    "default": {"cli": "claude", "model": "sonnet"},
    "architect": {"cli": "claude", "model": "opus"},
    "implementer": {"cli": "claude", "model": "sonnet"},
    "reviewer": {"cli": "claude", "model": "opus"},
    "documenter": {"cli": "claude", "model": "haiku"},
    "evaluator": {"cli": "claude", "model": "haiku"}
  }
}
```

The orchestrator reads this config and passes the appropriate `--model` flag.

**5.2 CLI abstraction**

Create a wrapper that normalizes different CLI tools:

```bash
hive_invoke_agent() {
    local agent="$1" prompt_file="$2" output_file="$3"
    local config=$(get_agent_config "$agent")
    local cli=$(echo "$config" | jq -r '.cli')
    local model=$(echo "$config" | jq -r '.model')

    case "$cli" in
        claude)
            cat "$prompt_file" | claude -p --model "$model" \
                --dangerously-skip-permissions 2>&1 | tee "$output_file"
            ;;
        codex)
            cat "$prompt_file" | codex --model "$model" \
                --approval-mode full-auto 2>&1 | tee "$output_file"
            ;;
        aider)
            aider --message-file "$prompt_file" --model "$model" \
                --yes-always 2>&1 | tee "$output_file"
            ;;
    esac
}
```

**5.3 Cost-aware model selection**

The orchestrator tracks spend and can downgrade models mid-run if budget is tight:

```bash
# If we've spent 80% of budget and still have 3 agents to go, downgrade
if budget_remaining < 20%; then
    switch remaining agents to haiku/sonnet
fi
```

### Files to modify
- `lib/orchestrator.sh` — replace direct `claude -p` call with `hive_invoke_agent`
- `lib/cost.sh` — budget tracking and model downgrade logic

### New files
- `lib/invoke.sh` — CLI abstraction layer

---

## Phase 6: Living Documentation

**Goal:** The system documents itself. CLAUDE.md grows with every run. The postmortem
becomes a narrative. The TUI shows the story, not just stats.

### Changes

**6.1 CLAUDE.md as living document**

Already described in Phase 2.1. Key addition: the documenter's final task every run
is to review what was learned and update CLAUDE.md. Not just "we used Nuxt" but
"when adding new pages in this project, always update both `app/routes.ts` and the
sidebar config in `components/layout/Sidebar.vue`."

**6.2 Rich postmortem narratives**

Replace the current dry stats postmortem with a narrative generated by a Haiku call:

```
Given this run's events, timeline, decisions, and challenges, write a 1-paragraph
summary a developer would want to read before starting their next task on this
codebase.
```

**6.3 Tool environment scanning**

During `hive init`, scan for available CLI tools and store in memory:

```bash
scan_tools() {
    local tools=()
    command -v docker &>/dev/null && tools+=("docker")
    command -v bq &>/dev/null && tools+=("bq")
    command -v psql &>/dev/null && tools+=("psql")
    command -v aws &>/dev/null && tools+=("aws")
    command -v kubectl &>/dev/null && tools+=("kubectl")
    command -v redis-cli &>/dev/null && tools+=("redis-cli")
    # Store in memory
    memory_update ".available_tools = [$(printf '"%s",' "${tools[@]}" | sed 's/,$//')]"
}
```

Injected into agent context: "You have access to: docker, psql, redis-cli"

**6.4 Improved human checkpoints**

Replace "Continue? [y/n]" with evaluator summaries:

```
🛑 CHECKPOINT: After architect

Completeness: ✓ all parts of objective addressed
Coherence:    ⚠ unclear how auth tokens refresh after upload  
Risk:         ⚠ no file size limit specified

Architect proposed 4 tasks, estimated ~2 hours implementation.

[C]ontinue  [D]etails  [R]eject  [Q]uit
```

### Files to modify
- `lib/postmortem.sh` — narrative generation
- `bin/hive` — tool scanning in init
- `lib/orchestrator.sh` — rich checkpoints with evaluator output
- `agents/documenter.md` — CLAUDE.md update as final task

---

## Implementation Order

Do these in order. Each phase builds on the previous.

```
Phase 1: Challenge Handoffs          ← agents push back on bad work
Phase 2: Compounding Knowledge       ← every run makes the next better  
Phase 3: Smart Orchestrator          ← routing decisions based on evidence
Phase 4: Parallel Worktrees          ← 3x throughput on independent tasks
Phase 5: Multi-Model Architecture    ← right model for right job
Phase 6: Living Documentation        ← system documents itself
```

Phase 1 and 2 can be done in a single session — they're mostly prompt changes and
small orchestrator additions. Phase 3 is the biggest lift. Phases 4-6 can be done
independently once Phase 3 is stable.

## Verification

After each phase, run:

```bash
# Syntax check all shell files
find ~/.hive -name "*.sh" -exec bash -n {} \; -print

# Verify agent prompts have valid JSON examples
for f in ~/.hive/agents/*.md; do
    echo "Checking $f..."
    grep -A 20 "HIVE_REPORT" "$f" | grep -o '{.*}' | jq empty 2>/dev/null || echo "  ⚠ JSON issue"
done

# Run a test workflow
hive run "add a health check endpoint" -w quick --no-interview
```

## Success Criteria

After all phases are implemented, this should be true:

1. An implementer that spots a wrong file path in the architect's plan challenges
   it instead of guessing
2. The 10th run on a project injects warnings about past mistakes into agent context
3. "Fix this typo" runs only the implementer, not the full 6-agent pipeline
4. Three independent tasks run in parallel worktrees
5. The reviewer uses Opus while the documenter uses Haiku
6. CLAUDE.md has a "Hive Learnings" section that grows with each run
7. Human checkpoints show evaluator verdicts, not just "continue?"
