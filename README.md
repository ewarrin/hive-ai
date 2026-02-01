# 🐝 Hive

AI agent orchestration for software development. Hive coordinates specialized Claude agents to build features, fix bugs, review code, and more.

## Quick Start

```bash
# Extract and install
tar -xzf hive-v2.tar.gz
cd hive
./install.sh

# Initialize in your project
cd your-project
hive init

# Run your first workflow
hive run "add user authentication with JWT"
```

## What It Does

Hive breaks down objectives into tasks and routes them through specialized agents:

```
You: "Add user profiles with avatar upload"
                    │
                    ▼
            ┌─────────────┐
            │  Architect  │ → Designs solution, creates tasks
            └─────────────┘
                    │
                    ▼
            ┌─────────────┐
            │ Implementer │ → Writes the code
            └─────────────┘
                    │
         ┌──────────┼──────────┐
         ▼          ▼          ▼
    ┌────────┐ ┌────────┐ ┌────────┐
    │ Tester │ │Reviewer│ │  UI    │  ← Run in parallel
    └────────┘ └────────┘ └────────┘
                    │
                    ▼
            ┌─────────────┐
            │ Documenter  │ → Writes docs
            └─────────────┘
                    │
                    ▼
              Pull Request
```

## Features

### 🔄 Workflows

```bash
hive run "objective"              # Auto-selects workflow
hive run -w feature "objective"   # Full pipeline
hive run -w bugfix "fix #123"     # Bug fix (debugger → test)
hive run -w refactor "cleanup"    # Refactor pipeline
hive run -w quick "small change"  # Minimal (just implement)
hive run -w docs "document API"   # Documentation only
```

### 📊 Real-time Monitoring

```bash
hive status --tui    # Interactive TUI
```

```
╭─ Hive Status ─────────────────────────────────────────╮
│                                                       │
│  Run: 20260131_163422   ● running   Elapsed: 4m 23s   │
│  Branch: hive/feature/add-user-profiles               │
│                                                       │
├─ Pipeline ────────────────────────────────────────────┤
│  ✓ architect      $0.02   "Designed profile..."       │
│  ✓ implementer    $0.06   "Implemented 4 files"       │
│  ● tester         $0.03   Running...                  │
│  ○ reviewer         —                                 │
╰───────────────────────────────────────────────────────╯
```

### 🔀 Git Integration

Automatic branch creation, commits per agent, PR creation:

```bash
hive run "add feature"
# → Creates branch: hive/feature/add-feature
# → Commits after each agent
# → Offers to push and create PR

hive git status      # View git state
hive git pr          # Create PR manually
```

### 🔍 Code Review Triage

Interactive review of findings with severity levels:

```
╭─ Code Review Findings ────────────────────────────────╮
│  🔴 Blocker (1)                                       │
│  ├─ [bd-a1b2] SQL injection in user query             │
│  🟠 High (3)                                          │
│  🟡 Medium (5)                                        │
╰───────────────────────────────────────────────────────╯

[F] Fix automatically  [A] Accept risk  [C] Continue
```

### 💰 Cost Tracking

```bash
hive cost              # Current run breakdown
hive cost --history    # Historical costs
```

### 🧠 Agent Memory

Agents learn from previous runs:
- Common issues in your codebase
- Patterns that worked or failed
- Project-specific gotchas

## Agents

| Agent | Purpose |
|-------|---------|
| **architect** | Designs solutions, creates tasks |
| **implementer** | Writes code |
| **tester** | Unit/integration tests |
| **e2e-tester** | Playwright/Cypress tests |
| **reviewer** | Code review |
| **security** | Security audit |
| **debugger** | Bug diagnosis |
| **ui-designer** | UI/UX improvements |
| **devops** | CI/CD, infrastructure |
| **documenter** | Documentation |

## Commands

```bash
hive init              # Initialize in project
hive run "objective"   # Run workflow
hive status --tui      # Real-time monitoring
hive doctor            # Check setup
hive git status        # Git integration status
hive findings          # View code review findings
hive cost              # Cost breakdown
hive workflows         # List available workflows
hive resume            # Resume from checkpoint
hive help              # All commands
```

## Requirements

- **bash** 4.0+
- **jq** (JSON processing)
- **Claude CLI** or **Beads** for task tracking
- **git** (optional, for git integration)
- **gh** (optional, for PR creation)

### Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| **Linux** | ✅ Full support | Works out of the box |
| **macOS** | ✅ Full support | Requires Bash 4+ (see below) |
| **WSL** | ✅ Full support | Use WSL2 for best experience |
| **Windows** | ⚠️ Via WSL/Git Bash | Native Windows not supported |

#### macOS: Install Bash 4+

macOS ships with Bash 3.2. Install Bash 4+ via Homebrew:

```bash
brew install bash

# Option 1: Run installer with new bash
/usr/local/bin/bash ./install.sh

# Option 2: Make it your default shell
sudo echo /usr/local/bin/bash >> /etc/shells
chsh -s /usr/local/bin/bash
```

#### Windows: Use WSL

```powershell
# Install WSL (PowerShell as Admin)
wsl --install

# Then in WSL terminal
sudo apt update && sudo apt install jq
# Follow normal Linux installation
```

## Configuration

### Environment Variables

```bash
HIVE_DIR=.hive              # Project-local directory
HIVE_ROOT=~/.hive           # Global installation
HIVE_GIT=1                  # Enable git integration (default)
HIVE_PARALLEL=1             # Enable parallel agents (default)
HIVE_AUTO_MODE=1            # Skip confirmations
HIVE_COST_INPUT=3.00        # $ per 1M input tokens
HIVE_COST_OUTPUT=15.00      # $ per 1M output tokens
```

### Custom Workflows

Create `.hive/workflows/myworkflow.json`:

```json
{
  "name": "myworkflow",
  "description": "My custom workflow",
  "phases": [
    {
      "name": "design",
      "agent": "architect",
      "required": true
    },
    {
      "name": "implement",
      "agent": "implementer",
      "required": true
    }
  ]
}
```

### Custom Agents

Create `.hive/agents/myagent.md` with agent instructions.

## Uninstall

```bash
./install.sh --uninstall
```

## License

MIT
