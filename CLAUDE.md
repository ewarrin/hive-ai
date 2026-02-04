# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hive is an AI agent orchestration system for software development. It coordinates specialized Claude agents (architect, implementer, tester, reviewer, etc.) to build features, fix bugs, and review code through pipeline workflows.

**Language:** Bash 4+
**Dependencies:** jq, Beads (`bd`), Claude CLI (`claude`), git (optional), gh (optional), Codex CLI (optional)

## Commands

```bash
# Installation
./install.sh                    # Install to ~/.hive
./install.sh --uninstall        # Remove

# Initialize in a project
hive init

# Run workflows
hive run "objective"            # Auto-select workflow
hive run -w feature "objective" # Full pipeline (architect→implementer→tester→reviewer)
hive run -w bugfix "fix #123"   # Debugger → Tester
hive run -w quick "small fix"   # Just implementer + build check
hive run -w refactor "extract auth" # Plan → implement → test → review (all required)
hive run -w test "test payment"     # Tester only
hive run -w review "review auth"    # Reviewer only
hive run -w docs "document API"     # Documenter only
hive run --only architect "plan migration"  # Single agent
hive run --auto "add timestamps"    # Skip human checkpoints
hive run -c docs/spec.md "implement API"  # With context files

# Monitoring & Status
hive status --tui               # Interactive dashboard (1-6 keys for views, q to quit)
hive events                     # View event log
hive events --tail              # Follow live
hive events --agent implementer # Filter by agent
hive cost                       # Cost breakdown
hive cost --history             # Cost over time
hive memory                     # View project knowledge
hive findings                   # View code review findings
hive findings --triage          # Interactive finding triage
hive doctor                     # Diagnose setup

# Resume & Recovery
hive checkpoints                # List available
hive resume                     # Resume most recent
hive comb                       # Resolve merge conflicts from parallel work

# Development verification
find ~/.hive -name "*.sh" -exec bash -n {} \; -print  # Syntax check all scripts
```

## Architecture

### Core Flow
```
User objective → orchestrator.sh → workflow phases → agent invocations → handoffs → final output
```

### Key Components

**Orchestration (`lib/`):**
- `orchestrator.sh` (54KB) - Main workflow loop, agent execution, validation
- `workflow.sh` - Built-in workflow templates (feature, bugfix, refactor, quick, docs)
- `router.sh` - Dynamic agent routing based on task type
- `parallel.sh` - Concurrent agent execution
- `validator.sh` - Contract enforcement via pre/post validation

**Agent Communication:**
- `handoff.sh` - Creates structured JSON handoff documents between agents
- `scratchpad.sh` - Shared mutable state during a run (`.hive/scratchpad.json`)
- `memory.sh` - Persistent project knowledge across runs (`.hive/memory.json`)

**Observability:**
- `logger.sh` - JSONL event logging with distributed trace support
- `selfeval.sh` - Parses HIVE_REPORT/HIVE_CRITIQUE blocks from agent output
- `tracing.sh` - Distributed tracing context (run_id, trace_id, span_id)

**Agents (`agents/*.md`):**
Each agent is a Markdown prompt template. Agents output structured `HIVE_REPORT` JSON blocks:
```markdown
<!--HIVE_REPORT
{
  "status": "complete|partial|blocked|challenge",
  "summary": "...",
  "confidence": 0.85
}
HIVE_REPORT-->
```

**Contracts (`contracts/*.json`):**
Define required inputs/outputs for each agent, used by `validator.sh` for pre/post validation. See `contracts/implementer.json` for structure example.

**Testing (`lib/testing.sh`):**
Multi-tier test orchestration: unit (Vitest/Jest), integration (Testing Library), E2E (Playwright with headed browser). Auto-detects existing test infrastructure.

### Data Flow

1. `orchestrator.sh::run_workflow()` iterates through workflow phases
2. Each phase: pre-validate → build prompt with context → invoke agent via `claude -p` → parse HIVE_REPORT → post-validate → create handoff → log events
3. Agents can challenge previous agent's work (Phase 0 in agent prompts)
4. Optional human checkpoints between phases

### State Files (per project)

```
.hive/
├── scratchpad.json   # Current run state
├── memory.json       # Persistent project knowledge
├── index.md          # Codebase map
├── events.jsonl      # Event log
├── runs/             # Historical run data
├── handoffs/         # Agent handoff documents
├── checkpoints/      # Resume points
├── agents/           # Project-local agent overrides
└── workflows/        # Custom workflow definitions
.beads/               # Beads task database (git-tracked)
hive.config.json      # Project-level model/feature config (optional)
```

## Key Patterns

**Agent invocation:** All agents are called via `claude -p` (or configured CLI backend) with the agent's markdown prompt plus injected context (handoffs, scratchpad, memory). Context is role-curated—architect gets full context, testers get diff + test framework info.

**Challenge workflow:** Each agent (except first) has Phase 0 that reviews previous agent's work. Can report `"status": "challenge"` to push back with a specific, evidenced objection. Max one challenge round—if unresolved, surfaces to human.

**File-based state:** Uses JSON files rather than in-memory state for persistence across process boundaries.

**Workflow composition:** Workflows can call sub-workflows (max depth 5) via `workflow_composition.sh`.

**Multi-model routing:** Different agents can use different CLI backends (Claude, Codex, aider) via `hive.config.json`. Common pattern: Claude opus for thinking agents (architect, reviewer), cheaper/faster model for execution agents (implementer, documenter).

## Configuration

**`hive.config.json`** (project root or `~/.hive/`):
```json
{
  "models": {
    "default": "sonnet",
    "architect": "opus",
    "implementer": "opus",
    "reviewer": "sonnet"
  },
  "features": {
    "testing_required": true,
    "parallel_worktrees": true,
    "auto_mode": false
  }
}
```

**Environment Variables:**
```bash
HIVE_DIR=.hive          # Project-local directory
HIVE_ROOT=~/.hive       # Global installation
HIVE_GIT=1              # Enable git integration
HIVE_AUTO_MODE=1        # Skip confirmations
HIVE_PARALLEL=1         # Enable parallel agents
HIVE_CONTEXT_FILES      # Space-separated list of context files to inject
```

## Customization

**Project-local agent overrides:** Copy agent from `~/.hive/agents/` to `.hive/agents/` and modify. Project-level takes precedence.

**Custom workflows:** Create JSON in `.hive/workflows/` with phases array. Each phase specifies agent, required flag, and optional human_checkpoint_after. Run with `hive run -w <name>`.
