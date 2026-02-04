# Getting Started with Hive

Hive is a command-line tool that coordinates specialized AI agents to build features,
fix bugs, review code, and more. You describe what you want. Hive breaks it into
tasks, assigns them to agents, and manages the entire workflow — design through
documentation.

This guide walks you through installation, first run, and the core concepts you need
to be productive.

---

## Prerequisites

Before installing Hive, you need three things on your machine.

### 1. Claude Code CLI

Hive uses Claude Code as its execution engine. Every agent runs as a Claude Code
session with a specialized prompt.

Install it with npm:

```bash
npm install -g @anthropic-ai/claude-code
```

After installing, run `claude` once to authenticate. You'll need a Claude Pro or Max
subscription, or an API key.

### 2. Beads

Beads is a git-backed task tracker designed for AI agents. Hive uses it to create
epics, decompose tasks, track dependencies, and know what's done.

**Mac:**

```bash
brew install steveyegge/beads/bd
```

**Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
```

**Windows (WSL):**

```bash
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
```

**Any platform with Go installed:**

```bash
go install github.com/steveyegge/beads/cmd/bd@latest
```

Verify with `bd --version`.

### 3. OpenAI Codex CLI (optional)

Hive supports multi-model routing — different agents can use different CLI backends.
By default everything runs through Claude Code, but you can configure agents like the
implementer or documenter to run through Codex instead. This lets you use the strongest
model for design-time thinking (architect, reviewer on Claude) and a fast model for
execution (implementer on Codex).

If you want to use Codex as a backend for any agents:

**Mac:**

```bash
brew install --cask codex
```

**Any platform with npm:**

```bash
npm install -g @openai/codex
```

**Linux (direct binary):**

Download the appropriate binary from [the latest GitHub release](https://github.com/openai/codex/releases),
rename it to `codex`, and place it somewhere in your PATH.

After installing, run `codex` to authenticate. You'll need a ChatGPT Plus, Pro, Team,
or Enterprise account, or an OpenAI API key.

Verify with `codex --version`.

To configure which agents use Codex, see the [Configuring Agent Backends](#configuring-agent-backends)
section below.

### 4. jq

Hive uses jq extensively for parsing agent output and managing state.

**Mac:**

```bash
brew install jq
```

**Linux (Debian/Ubuntu):**

```bash
sudo apt install jq
```

**Linux (Fedora):**

```bash
sudo dnf install jq
```

**Windows (WSL):**

```bash
sudo apt install jq
```

---

## Platform-Specific Setup

### macOS

macOS ships with Bash 3.2, but Hive requires Bash 4+. You need to install a modern
Bash before running the installer.

```bash
# Install Bash 4+ via Homebrew
brew install bash

# Verify
/usr/local/bin/bash --version   # Intel Mac
/opt/homebrew/bin/bash --version # Apple Silicon
```

You don't need to change your default shell. The installer and Hive itself will use
the Homebrew bash automatically via the `#!/usr/bin/env bash` shebang as long as it's
in your PATH. If you run into issues, you can explicitly invoke:

```bash
/opt/homebrew/bin/bash ./install.sh
```

**Other recommended tools:**

```bash
brew install git gh
brew install --cask codex   # Optional: use Codex as a backend for some agents
```

`gh` (GitHub CLI) is optional but enables automatic pull request creation at the end
of workflows. `codex` is optional but lets you route agents through OpenAI's models.

### Linux

Most Linux distributions ship with Bash 4+ and git already installed. You likely only
need jq and the Claude/Beads prerequisites.

**Debian/Ubuntu:**

```bash
sudo apt update
sudo apt install bash jq git curl
```

**Fedora:**

```bash
sudo dnf install bash jq git curl
```

**Arch:**

```bash
sudo pacman -S bash jq git curl
```

Optional: `sudo apt install gh` (or equivalent) for GitHub CLI integration.
Optional: `npm install -g @openai/codex` to use Codex as an agent backend.

### Windows

Hive runs on Windows through WSL (Windows Subsystem for Linux). Native Windows is
not supported — the tool is written in Bash and relies on Unix utilities.

**Step 1: Install WSL**

Open PowerShell as Administrator:

```powershell
wsl --install
```

This installs Ubuntu by default. Restart your computer when prompted.

**Step 2: Open your WSL terminal and install prerequisites**

```bash
sudo apt update
sudo apt install bash jq git curl

# Install Node.js (for Claude Code CLI and optionally Codex CLI)
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install nodejs

# Install Claude Code
npm install -g @anthropic-ai/claude-code

# Install Beads
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# Optional: Install Codex CLI to use as an agent backend
npm install -g @openai/codex
```

**Step 3: Access your Windows files**

Your Windows filesystem is available at `/mnt/c/`. You can work on projects stored
there, but for best performance, keep projects inside the WSL filesystem (your home
directory).

```bash
# Good — fast, native Linux filesystem
cd ~/projects/my-app

# Works but slower — Windows filesystem through WSL
cd /mnt/c/Users/yourname/projects/my-app
```

---

## Installing Hive

Once prerequisites are in place, installation is the same on all platforms.

**From the tarball:**

```bash
tar -xzf hive-v2.tar.gz
cd hive
./install.sh
```

**With custom install location:**

```bash
./install.sh --prefix ~/tools/hive
```

The installer copies files to `~/.hive/`, adds it to your PATH, and verifies
everything works. When it finishes, reload your shell:

```bash
source ~/.zshrc    # macOS (zsh)
source ~/.bashrc   # Linux / WSL
```

**Verify the installation:**

```bash
hive --version
hive doctor
```

`hive doctor` runs a full diagnostic — it checks Bash version, jq, Claude CLI, Beads,
git, GitHub CLI, Codex CLI, and reports what's working and what's missing.

---

## Your First Run

### Step 1: Initialize Hive in your project

Navigate to any git-tracked project and run:

```bash
cd ~/projects/my-app
hive init
```

This creates a `.hive/` directory in your project root. It also initializes Beads
(`.beads/`) if it isn't already present, detects your framework and package manager,
and writes initial project memory.

### Step 2: Run a workflow

```bash
hive run "add a user profile page with avatar upload"
```

Here's what happens:

1. **Interviewer** (optional) — asks clarifying questions about the objective
2. **Architect** — analyzes the codebase, designs a solution, creates tasks in Beads
3. **Human checkpoint** — you review the architect's plan and approve or adjust it
4. **Implementer** — writes the code according to the plan
5. **Build check** — verifies the code compiles
6. **Tester** — writes and runs tests
7. **Reviewer** — reviews the code for quality, security, and correctness
8. **Documenter** — adds documentation

Each agent produces a structured report and hands off to the next. If a build fails,
the debugger agent is called automatically.

### Step 3: Monitor progress

While a workflow runs, open a second terminal and watch it in real-time:

```bash
hive status --tui
```

The TUI shows the pipeline status, current agent, task progress, files changed, and
a timeline of the run. Navigate between views with the number keys:

- `1` — Overview (pipeline + tasks)
- `2` — Files changed
- `3` — Tasks
- `4` — Cost tracking
- `5` — Git status
- `6` — Timeline
- `q` — Quit

---

## Choosing a Workflow

Not every change needs the full pipeline. Hive has built-in workflows sized to the
work.

**Feature** (default) — the full pipeline. Architect designs, implementer builds,
tester tests, reviewer reviews, documenter documents. Use for new features, major
changes, anything that benefits from a plan-first approach.

```bash
hive run "add user authentication with JWT"
hive run "redesign the settings page"
```

**Quick** — just the implementer and a build check. No design phase, no tests, no
review. Use for small, obvious changes where you already know what needs to happen.

```bash
hive run -w quick "add a loading spinner to the dashboard"
hive run -w quick "change the page title to Welcome"
```

**Bugfix** — skips the architect, goes straight to the debugger. Then tests to verify
the fix. Use when you know something is broken and need it fixed.

```bash
hive run -w bugfix "fix login error when email has + symbol"
hive run -w bugfix "dashboard crashes when user has no avatar"
```

**Refactor** — architect plans the refactoring, implementer executes, tester verifies
nothing broke, reviewer checks quality. All phases are required.

```bash
hive run -w refactor "extract auth logic into a shared middleware"
```

**Test** — runs only the tester agent. Use when the code is written and you need test
coverage.

```bash
hive run -w test "write tests for the payment module"
```

**Review** — runs only the reviewer agent. Use for code review on recent changes.

```bash
hive run -w review "review the auth changes from today"
```

**Docs** — documenter writes or updates documentation, reviewer optionally checks it.

```bash
hive run -w docs "document the REST API endpoints"
```

---

## Working with Agents Directly

Sometimes you want to run a single agent rather than a full workflow. The `--only`
flag lets you do that.

```bash
# Just get the architect's plan without executing it
hive run --only architect "plan the auth module refactor"

# Just implement — you already know what to build
hive run --only implementer "add rate limiting to the API"

# Just test what was already built
hive run --only tester "test the new payment flow"

# Just review
hive run --only reviewer "review recent changes"
```

This is useful for a surgical, multi-step approach where you want to control each
phase:

```bash
hive run --only architect "redesign the notification system"
# Review the plan, make adjustments
hive run --only implementer "implement the notification redesign"
# Check the output
hive run --only tester "test notification system"
```

---

## Providing Context

If you have a spec document, design file, or any reference material, pass it to Hive
with the `--context` flag. The file contents get injected into every agent's prompt.

```bash
hive run "implement the API" -c docs/api-spec.md
hive run "build the dashboard" -c designs/dashboard-wireframe.md -c docs/requirements.md
```

You can pass `-c` multiple times for multiple files.

---

## Autonomous Mode

By default, Hive pauses at human checkpoints — after the architect produces a plan,
after blocking issues are found, and at other key decision points. You review and
approve before the pipeline continues.

For well-understood tasks on mature projects, you can skip the checkpoints:

```bash
hive run --auto "add created_at timestamp to all models"
```

Use this for overnight runs, batch tasks, or changes where you trust the system to
make the right calls. The postmortem report will tell you everything that happened.

---

## What Hive Creates in Your Project

After `hive init`, your project contains:

```
your-project/
├── .hive/                  # Hive's working directory
│   ├── runs/               # Artifacts from each run
│   │   └── 20260201_143000/
│   │       ├── config.json     # Run configuration
│   │       ├── events.jsonl    # Event log (every action)
│   │       ├── handoffs/       # Agent-to-agent handoff documents
│   │       ├── output/         # Raw agent output
│   │       └── report.md       # Post-mortem report
│   ├── scratchpad.json     # Shared agent memory for current run
│   ├── checkpoints/        # Resume points
│   ├── agents/             # Project-specific agent overrides
│   ├── workflows/          # Custom workflow definitions
│   └── index.md            # Codebase index (auto-generated)
│
├── .beads/                 # Beads task database (git-tracked)
│   └── *.jsonl             # Task data
│
└── ... your code
```

Both `.hive/` and `.beads/` should be committed to git. The event logs and handoff
documents are useful for debugging, and Beads task state needs to persist across
sessions.

---

## Useful Commands

After your first run, these commands help you understand what happened and manage
ongoing work.

**Check what Hive learned about your project:**

```bash
hive memory
```

Hive tracks your framework, package manager, build commands, patterns it discovered,
and conventions it learned from previous runs.

**View cost breakdown:**

```bash
hive cost
hive cost --history
```

See token usage and estimated cost per agent, per run, or over time.

**Review findings from code review:**

```bash
hive findings
hive findings --triage
```

The reviewer files issues as Beads tasks. `--triage` opens an interactive interface
to accept, reject, or defer each finding.

**View the event log:**

```bash
hive events
hive events --tail          # Follow live
hive events --agent implementer  # Filter by agent
```

Every action is logged as structured JSON — agent starts, handoffs, decisions,
errors, completions. Useful for understanding exactly what happened during a run.

**Resume from a checkpoint:**

```bash
hive checkpoints            # List available
hive resume                 # Resume most recent
hive resume --checkpoint 20260201_143000  # Resume specific
```

If a run fails or you stop it, Hive saves state. You can pick up where it left off.

**Resolve merge conflicts from parallel work:**

```bash
hive comb
```

The comb agent understands what each branch was trying to accomplish and resolves
conflicts by preserving both intents.

---

## Configuring Hive

### Project-Level Agent Overrides

If you need an agent to behave differently for a specific project — maybe your
implementer should always use a particular CSS framework, or your tester should
focus on specific test patterns — create an override in `.hive/agents/`:

```bash
cp ~/.hive/agents/implementer.md .hive/agents/implementer.md
# Edit the copy
```

Project-level agents take precedence over global ones.

### Custom Workflows

Create a JSON file in `.hive/workflows/` to define a custom pipeline:

```json
{
  "name": "api-feature",
  "description": "API feature with security review",
  "phases": [
    { "name": "design", "agent": "architect", "required": true, "human_checkpoint_after": true },
    { "name": "implementation", "agent": "implementer", "required": true },
    { "name": "build_check", "type": "build_verify", "required": true },
    { "name": "security", "agent": "security", "required": true },
    { "name": "testing", "agent": "tester", "required": true },
    { "name": "review", "agent": "reviewer", "required": true }
  ]
}
```

Then run it:

```bash
hive run -w api-feature "add payment processing endpoint"
```

### Global Workflows

For workflows you use across multiple projects, put them in `~/.hive/workflows/`.

### Configuring Agent Backends

By default, every agent runs through Claude Code. Hive supports routing individual
agents through different CLI backends — Claude, Codex, or aider — so you can use the
right model for each job.

Add a `models` section to `.hive/config.json`:

```json
{
  "models": {
    "default": {"cli": "claude", "model": "sonnet"},
    "architect": {"cli": "claude", "model": "opus"},
    "implementer": {"cli": "codex", "model": "gpt-5.2-codex"},
    "reviewer": {"cli": "claude", "model": "opus"},
    "documenter": {"cli": "claude", "model": "haiku"},
    "evaluator": {"cli": "claude", "model": "haiku"}
  }
}
```

The `cli` field determines which tool runs the agent. The `model` field is passed
through to that tool's `--model` flag. Any agent not listed falls back to `default`.

Supported backends:

| Backend | CLI | Install | Auth |
|---------|-----|---------|------|
| **Claude Code** | `claude` | `npm install -g @anthropic-ai/claude-code` | Claude subscription or API key |
| **Codex** | `codex` | `npm install -g @openai/codex` | ChatGPT subscription or OpenAI API key |
| **aider** | `aider` | `pip install aider-install && aider-install` | Any LLM API key |

A common pattern is to keep Claude on the thinking agents (architect, reviewer) where
deep reasoning matters, and route the execution agents (implementer, documenter) through
a cheaper or faster backend. Hive also tracks spend per agent — if you're over budget
mid-run, you can configure automatic model downgrade in the cost settings.

---

## The Agents

Hive ships with these specialized agents:

| Agent | Role | When It Runs |
|-------|------|--------------|
| **Interviewer** | Asks clarifying questions about the objective | Start of feature workflow |
| **Architect** | Analyzes codebase, designs solution, creates tasks | Design phase |
| **Implementer** | Writes code according to the architect's plan | Implementation phase |
| **Tester** | Writes and runs unit/integration tests | Testing phase |
| **E2E Tester** | Writes end-to-end tests (Playwright) | When configured |
| **Component Tester** | Tests individual UI components | When configured |
| **UI Designer** | Reviews and improves frontend quality | Feature workflow with frontend |
| **Reviewer** | Code review for quality, security, correctness | Review phase |
| **Security** | Focused security audit | When configured |
| **Debugger** | Diagnoses and fixes build/test failures | On failure |
| **Documenter** | Writes documentation and code comments | Documentation phase |
| **Comb** | Resolves merge conflicts from parallel work | `hive comb` |

Each agent has a structured prompt, a contract defining its inputs and outputs, and
integration with Beads for task tracking. Agents produce handoff documents for the
next agent in the pipeline, and the orchestrator validates each handoff before
proceeding.

---

## Troubleshooting

### `hive doctor` reports issues

Run `hive doctor --fix` to attempt automatic fixes. For manual issues:

- **Bash version too old (macOS):** `brew install bash` and ensure `/opt/homebrew/bin`
  is early in your PATH
- **jq not found:** Install with your package manager
- **Claude CLI not found:** `npm install -g @anthropic-ai/claude-code` and run `claude`
  once to authenticate
- **Codex CLI not found (optional):** `npm install -g @openai/codex` or
  `brew install --cask codex` on Mac. Run `codex` to authenticate. Only needed if
  you've configured agents to use the Codex backend.
- **Beads not found:** Follow the Beads installation instructions above

### Agent fails repeatedly

Check the event log for specifics:

```bash
hive events --agent implementer
```

Common causes: the objective is too vague (the architect produces a vague plan, the
implementer can't execute it), the codebase has patterns the agent doesn't expect, or
a dependency isn't installed.

If an agent fails 3 times, Hive stops and surfaces the issue to you at a checkpoint
with the error details.

### Build verification fails

The build check runs your project's build command (detected from package.json,
Makefile, Cargo.toml, etc.). If it fails, the debugger agent is called automatically.
If the debugger can't fix it:

```bash
# See what went wrong
hive events --tail

# Fix it manually, then resume
hive resume
```

### WSL-specific issues

- **Slow filesystem:** Keep projects in `~/` not `/mnt/c/`
- **Git line endings:** Set `git config --global core.autocrlf input`
- **Node.js version:** Use the NodeSource repository, not the default Ubuntu package

### Uninstalling

```bash
./install.sh --uninstall
```

This removes `~/.hive/`, cleans PATH entries from your shell profile, and leaves your
projects' `.hive/` directories untouched.

---

## Next Steps

Once you're comfortable with basic workflows:

- Read `PHILOSOPHY.md` to understand the design principles behind Hive
- Read `PLAN.md` to see where Hive is headed (challenge handoffs, compounding
  knowledge, parallel execution)
- Create project-specific agent overrides for your codebase
- Build custom workflows for your team's development patterns
- Try autonomous mode on well-understood tasks
- Explore `hive findings --triage` for interactive code review management
