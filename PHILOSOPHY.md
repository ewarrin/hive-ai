# The Hive Philosophy

## Why "Hive"

A bee colony isn't managed. There's no project plan pinned to the wall of the hive.
Each bee has a role — forager, builder, nurse, guard — and the colony's intelligence
emerges from how they communicate on the handoff. A forager returns with nectar and
dances. The dance *is* the information. Other bees interpret it, make decisions, and
act. No bee tells another bee what to do. They respond to signals.

That's the idea.

Hive isn't a pipeline. It's a colony of specialized agents that communicate through
structured handoffs, challenge each other's work, and produce results that no single
agent could produce alone. The intelligence isn't in any one agent. It's in the
spaces between them.

---

## The Core Beliefs

### 1. Quality lives in the handoff, not the agent

A brilliant architect who produces a vague plan creates more damage than a mediocre
architect who produces a precise one. The implementer doesn't care how smart the
architect is. It cares whether the plan has enough detail to write code without
guessing.

Most AI workflows treat handoffs as plumbing — invisible infrastructure that moves
data from A to B. Hive treats handoffs as the *primary site of quality*. Every
transition between agents is an opportunity for the receiving agent to challenge what
it was given. "Your plan references a file that doesn't exist." "Your implementation
doesn't match what the architect designed." "Your tests only cover the happy path."

This is how real teams work. A good developer doesn't blindly implement a spec they
know is wrong. They push back. They ask questions. They say "this won't work because"
before writing a line of code. Agents should do the same.

### 2. Knowledge must compound

Session 1 and session 50 on the same project should feel completely different. Not
because the agents got smarter — they didn't — but because the *environment* got
richer. CLAUDE.md grew. Project memory accumulated patterns. The orchestrator learned
which agents struggle with what. Warnings got injected before mistakes could repeat.

Most AI tools produce throwaway outputs. You ask, you get an answer, it evaporates.
The next session starts from zero. This is like hiring a brilliant contractor who gets
amnesia every night. Every morning you explain everything again.

Hive's ambition is that every run leaves the project in a better state for the next
run. Not just in the code it produces, but in the *knowledge infrastructure* that
surrounds the code. The learnings section in CLAUDE.md. The per-agent mistake history.
The conventions documented by the reviewer. The gotchas caught by the tester. All of
it persists. All of it feeds forward.

The 50th run should feel like working with a team that has been on the project for
months.

### 3. The orchestrator should think, not just schedule

A for-loop that walks through agents in order is not orchestration. It's a cron job
with extra steps.

Real orchestration means reading the architect's report and deciding whether the
implementer can succeed with it. It means recognizing that "fix this typo" doesn't
need six agents. It means noticing that the tester has failed three times on the same
error and routing to the debugger instead of retrying a fourth time. It means
tracking spend and downgrading models when the budget gets tight.

The orchestrator is the project manager. Not in the corporate sense — in the sense
of someone who reads the room, makes judgment calls, and adapts the plan when reality
diverges from the script. That's the aspiration.

### 4. Agents are collaborators, not tools

A tool does what you tell it. A collaborator tells you when your plan is wrong.

This is the most important shift. When you treat AI as a tool, you get prompts. When
you treat AI as a collaborator, you get systems. The difference is whether the agent
has *agency* — whether it can say "no, this won't work" and have that mean something.

In Hive, agents have contracts, not just instructions. They have the ability to
challenge. They have confidence thresholds below which they stop and ask for help
instead of producing garbage. They have the ability to file new tasks when they
discover work the architect missed. They don't just execute — they participate.

### 5. The human stays in the loop where it matters

Not everywhere. Not on every decision. But at the decision points that actually
require human judgment.

Hive has checkpoints. But checkpoints that just say "Continue? [y/n]" are theater.
Real checkpoints surface the evaluator's analysis: "The architect addressed 4 of 5
requirements. The missing one is file upload error handling. The risk evaluator says
this is the most likely failure point in production. Continue?"

That gives the human something to *decide*, not just rubber-stamp.

The design principle: autonomy within bounds. Let agents work independently on
implementation details. Pause for decisions that involve tradeoffs, ambiguity, or
risk. And make the pause useful by showing the human what the system actually thinks,
not just that it stopped.

### 6. You have to know it worked

Code that compiles is not code that works. A green CI badge is not proof of
correctness. An agent that says "done" is not an agent that finished.

The hardest problem in AI-assisted development isn't getting the code written. It's
knowing whether the code does what you asked for. An implementer can produce a
beautiful component that renders nothing. A tester can write tests that pass but don't
test the actual behavior. An e2e suite can run headless and miss that the button it
"clicked" was behind a modal.

Hive treats verification as a first-class concern, not a nice-to-have bolted on at
the end. Testing is required in feature and bugfix workflows — not optional, not
skippable, not "we'll add tests later." The system creates tests at multiple tiers:
unit tests to verify logic, integration tests to verify wiring, and e2e tests to
verify that the thing actually works in a browser with real clicks and real rendering.

But even tests aren't enough. Tests verify behavior against assertions a developer
wrote. They don't verify that the user experience is correct. That's why Hive includes
visual validation — a browser-validator agent that takes screenshots, inspects what
rendered, and compares it against what was intended. Did the button appear? Is it in
the right place? Does the layout break on narrow viewports? These are questions that
unit tests can't answer and integration tests won't catch.

The principle: verification should be as concrete as possible. Run the tests. Open the
browser. Take the screenshot. Show me the proof. If you can't demonstrate that it
worked, it didn't work.

---

The naming isn't decorative. It shapes how we think about the system.

**The Hive** is the project. The `.hive/` directory is the colony's memory — the
scratchpad, the event log, the handoffs, the accumulated knowledge. It persists
across runs the way a hive persists across seasons.

**Agents are specialized bees.** The architect is the scout — it goes out, surveys
the landscape, and returns with a plan. The implementer is the builder — it
constructs the comb according to the plan. The tester is the guard — it checks the
work for threats. The reviewer is the inspector — it evaluates quality before the
work is sealed. The comb agent weaves parallel work together, like bees packing
honey from different foragers into the same cells.

**The orchestrator is not the queen.** The queen doesn't manage. She's the
reproductive center — important, but not the decision-maker. The orchestrator is
more like the collective pheromone signal that coordinates the colony. It responds
to what's happening — this agent succeeded, that one failed, this one challenged —
and routes accordingly. No central plan. Emergent coordination from local signals.

**Handoffs are dances.** When a forager returns, it dances to communicate what it
found — direction, distance, quality. That dance is the handoff document. It's
structured. It's interpretable. It carries the information the next bee needs to do
its job. The quality of the dance determines the quality of the response.

---

## What Hive Is Not

**Hive is not a prompt library.** Prompts are Level 1 thinking — you pick up a tool,
use it, put it down. Hive is a system. The agent prompts are one component. The
contracts, the handoffs, the memory, the orchestration logic, the challenge mechanism
— those are the system. The prompts without the system are just words.

**Hive is not a replacement for thinking.** You still need to write good objectives.
You still need to review the architect's plan at the checkpoint. You still need to
read the code the implementer produces. Hive amplifies your judgment. It doesn't
substitute for it.

**Hive is not autonomous.** Not yet, and maybe not ever fully. The overnight "Ralph
Wiggum mode" runs work for well-understood tasks on mature projects. But for anything
novel — new architecture, unfamiliar patterns, ambiguous requirements — the human
needs to be present at the checkpoints. The system is designed to make your presence
*efficient*, not to eliminate it.

**Hive is not finished.** It started as a bash script called Gastown, named after a
Mad Max refinery. Then it was Loom, weaving agents together. Then it became Hive —
a colony with memory, communication, and emergent intelligence. Each version got
closer to the idea. None have arrived. The philosophy describes where we're going,
not where we are.

---

## The Operating Agreements

Every collaboration needs agreements about how the participants work together. These
are Hive's.

**Decision authority.** The architect proposes the approach. The human approves it at
the checkpoint. The implementer executes it. The reviewer evaluates it. No agent makes
strategic decisions autonomously. Implementation details — naming conventions, import
patterns, error handling style — are decided by matching whatever the codebase already
does.

**Escalation triggers.** An agent stops and reports back when: confidence drops below
the threshold, the plan contradicts the codebase reality, requirements conflict with
each other, or the work requires a decision that wasn't covered in the objective. The
agent should never silently swallow uncertainty. That's where bad code comes from.

**Challenge rights.** Every agent (except the first in the pipeline) has the right to
challenge what it was handed. A challenge is not a complaint — it's a specific,
evidenced objection with a suggested resolution. "Your plan references
`src/auth/middleware.ts` but that file doesn't exist. Did you mean
`server/middleware/auth.ts`?" The orchestrator routes challenges back. Maximum one
round — if it can't be resolved between agents, it surfaces to the human.

**Visible reasoning.** Agents show their work. The architect explains why it chose
this approach over alternatives. The implementer documents decisions it made during
implementation. The evaluator shows its gap analysis. The human can see the reasoning,
challenge it, and improve the system. If you can't see the reasoning, you can't
improve the system.

**What persists.** CLAUDE.md grows with every run. Project memory accumulates patterns
and conventions. Agent performance history tracks mistakes and strengths. Run artifacts
(event logs, handoffs, reports) are kept forever. Decisions are append-only — you can
always trace back to why something was done a certain way.

---

## The Path

Hive's evolution follows a progression. Each level requires the ones before it.

**Level 1: Agents that execute.** Each agent has a role, a prompt, and a contract.
The orchestrator runs them in sequence. This is where Hive started — Gastown, a
sequential pipeline with validation.

**Level 2: Agents that communicate.** Structured handoffs between agents. Shared
scratchpad. Event logging. The receiving agent knows what the sending agent did and
why. This is Hive v1-v2.

**Level 3: Agents that challenge.** Agents critically review what they receive before
doing their own work. The implementer pushes back on a bad plan. The tester pushes
back on incomplete implementation. Quality emerges from friction. This is Hive v4's
core addition.

**Level 4: A system that learns.** Every run makes the next run better. CLAUDE.md
grows. Memory compounds. The orchestrator adapts based on history. The 50th run is
dramatically more capable than the first — not because the agents changed, but because
the environment they work in got richer. This is where Hive is heading.

**Level 5: A system that thinks.** The orchestrator plans before executing. It
evaluates between agents. It routes dynamically based on what's happening. It manages
budget. It dispatches parallel work. It's not a loop — it's a project manager. This
is the horizon.

Each level collapses without the ones below it. You can't have agents that learn if
they don't communicate. You can't have agents that challenge if they don't understand
what they received. You can't have an orchestrator that thinks if the agents don't
produce structured, evaluable output.

Build the foundation. The intelligence emerges.

---

## The Test

You know Hive is working when:

- The implementer refuses to start because the architect's plan references files
  that don't exist
- The 10th run on a project takes half the tokens of the 1st because the context
  is richer and fewer mistakes get made
- You read the architect's plan at the checkpoint and think "yes, that's exactly
  what I would have designed"
- The reviewer catches a bug that a human code reviewer would catch
- The postmortem tells you something useful about the run, not just that it happened
- You can leave it running overnight on a well-understood project and come back to
  a clean pull request
- A feature run produces unit tests, integration tests, and e2e tests without being
  asked — because testing is required, not optional
- You run `npm run test:unit` after a Hive run and everything passes
- The browser-validator takes a screenshot and you can see the feature rendered
  correctly
- Playwright spins up a headed browser and the test clicks the actual button, not
  a phantom element

You know Hive is *not* working when:

- Agents produce output that nobody reads
- The human rubber-stamps every checkpoint without looking
- The same mistake happens on run 20 that happened on run 1
- Agents blindly execute plans they should have challenged
- The orchestrator runs all six agents for a one-line typo fix
- Confidence scores are always 0.85 regardless of what actually happened
- The implementer says "done" but the feature doesn't render
- Tests exist but don't test the actual behavior that was requested
- The e2e suite runs headless and reports green while the UI is broken
- Nobody opens a browser to check whether the thing actually works

The gap between those two lists is the work.
