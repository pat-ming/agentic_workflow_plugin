# agentic-workflow-plugin

**An autonomous, phase-based project builder for Claude Code — built to mimic one person's development style.**

With the advent of AI, one-time prompts can be slow when building projects. This plugin removes the human from the build loop and lets the agent code autonomously. You may ask what this does differently from `claude --dangerously-skip-permissions`. I'd argue that where *dangerously-skip-permissions* answers *"can the agent act without asking?"*, this plugin answers *"how do I **know** what the agent did is correct without checking it myself?"* — a slightly different, and for me worthwhile, optimization.

At its core this is a personal agent I built for my own purposes. I have a specific way I like to build, and this workflow mimics it: an unsupervised, phase-based agentic pipeline for building projects end-to-end from a single prompt.

**Core loop:** `Plan → Implement → Verify → Clean → Commit → Next`

## How correctness is enforced

The central idea is **frozen verifiers**. Before any implementation exists, the orchestrator writes one machine-checkable pass/fail verifier per phase into a `verifiers/` directory. A `PreToolUse` hook then blocks any edit or deletion under `verifiers/` for the rest of the run, so the implementing agent can never grade its own homework or move the passing bar (no reward hacking). A phase is "done" only when its own verifier passes **and** every earlier verifier still passes.

The filesystem and git are the agent's shared memory: every durable decision becomes a file or a commit, never something held only in context.

## Components

This is a standard Claude Code plugin. Its pieces:

| Path | What it is |
| --- | --- |
| `.claude-plugin/plugin.json` | Plugin manifest (name, version, author). |
| `commands/build.md` | The `/build` slash command — the **orchestrator**. Holds the plan and all judgment; delegates implementation to fresh worker sessions and reads results back from disk. Never writes product code itself. |
| `agents/verifier_builder.md` | Subagent invoked once per phase during scaffolding. Encodes acceptance criteria the orchestrator supplies into a single frozen pass/fail verifier script. An encoder, not a judge — it never decides what "correct" means. |
| `agents/repo_scan_clean.md` | Read-only subagent invoked after a phase verifies. Diff-scoped (looks only at the phase's uncommitted changes) and proposes dead-file deletions and `.gitignore` additions back to the orchestrator. Makes zero changes itself. |
| `agents/finalizer.md` | Subagent invoked once in Phase 3. Judges whether the project is research or engineering and writes `SUMMARY.md` and `README.md` grounded strictly in what exists on disk. |
| `skills/notify/` | `notify` skill — pushes a phone notification via [ntfy](https://ntfy.sh) on a full success or a halting failure. `SUMMARY.md` is sent as the attachment. |
| `hooks/` | Plugin-level hook scripts (`verifier_freeze.sh`, `auto_verify.sh`, `completion_ping.sh`) and `hooks.json`. **Work in progress / scaffolding** — currently empty; the live guardrail hooks are written by the orchestrator into each target repo's `.claude/settings.json` during Phase 1. |

## Installation

Clone the plugin and point Claude Code at it with `--plugin-dir`:

```bash
git clone <this-repo> ~/plugins/agentic-workflow-plugin
```

Then run Claude Code with the plugin directory loaded (see usage below). The
`/build` command is manual-invocation only (`disable-model-invocation: true`) — the
model will not trigger it on its own.

### Notify skill setup (optional)

`skills/notify/SKILL.md` carries a private ntfy topic and is **git-ignored** on
purpose — the topic name is the only secret on ntfy, so it stays untracked.
`skills/notify/sample_SKILL.md` is the shareable template. To use notifications,
copy the sample to `SKILL.md` and set your own unguessable topic.

## Usage

Invoke the builder with a description of what to build:

```
/build A RL environment for Linear Algebra problems
```

The orchestrator then runs three phases:

1. **Scaffolding** — analyze the request and its dependency order; write `PLAN.md` (ordered phases, each with a `Pending / In-progress / Verified / Failed` status), all frozen verifiers under `verifiers/`, a stack-appropriate `.gitignore`, a `CLAUDE.md` of conventions, and `.claude/settings.json` with the guardrail hooks; then `git init` and commit the scaffold.
2. **Work loop** — for each phase: mark it in-progress, implement it in a fresh headless `claude -p` worker pointed at `PLAN.md`/`CLAUDE.md`, verify against the full suite so far, write a `results/phase_<N>.md` writeup, run the cleanup subagent, and commit exactly once. Each phase has a **retry budget of 3**; on exhaustion it records `FAILURE_phase_<N>.md`, resets to the last good commit, and stops rather than looping forever.
3. **Finalization** — write `SUMMARY.md` and `README.md`, do a final deep-scan cleanup, and run an acceptance check that clones the repo into a fresh directory, installs from scratch, and runs the entire verifier suite to prove the build reproduces from nothing.

### Running it unattended

The workflow is designed to run headless and autonomously. A typical invocation:

```bash
caffeinate -i nohup claude -p "/build create an RL environment for chemistry problems" \
  --plugin-dir ~/plugins/agentic-workflow-plugin \
  --dangerously-skip-permissions \
  --output-format stream-json --verbose > build.log 2>&1 &
```

Workers spawned by the orchestrator run as separate `claude -p` processes; they do
**not** inherit the orchestrator's permissions or loaded plugin, so each worker
command passes `--dangerously-skip-permissions` explicitly and is pointed at
`PLAN.md` and `CLAUDE.md`.

> Note: `--dangerously-skip-permissions` lets the agent act without prompts. Run it
> only on work you're comfortable executing unattended.

## Author

Patrick Ming
