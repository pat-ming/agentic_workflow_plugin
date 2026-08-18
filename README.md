# agentic-workflow-plugin

**An autonomous, phase-based project builder for Claude Code — built to mimic one person's development style.**

With the advent of AI, one-time prompts can be slow when building projects. This plugin removes the human from the build loop and lets the agent code autonomously. You may ask what this does differently from `claude --dangerously-skip-permissions`. I'd argue that where *dangerously-skip-permissions* answers *"can the agent act without asking?"*, this plugin answers *"how do I **know** what the agent did is correct without checking it myself?"* — a slightly different, and for me worthwhile, optimization.

At its core this is a personal agent I built for my own purposes. I have a specific way I like to build, and this workflow mimics it: an unsupervised, phase-based agentic pipeline for building projects end-to-end from a single prompt.

**Core loop:** `Plan → Implement → Verify → Clean → Commit → Next`

## How correctness is enforced

Four mechanisms, layered:

1. **Frozen verifiers.** Before any implementation exists, the orchestrator decides what "done" means for every phase and has the `verifier_builder` agent encode each definition into a machine-checkable pass/fail script under `verifiers/`. From that point on the verifiers are frozen: a `PreToolUse` hook blocks any write, edit, or delete under `verifiers/` for the rest of the run, so the implementing agent can never grade its own homework or move the passing bar.
2. **Full-suite regression.** A phase is "done" only when its own verifier passes **and** every earlier verifier still passes. New work that silently breaks old work fails the phase.
3. **Fresh-clone acceptance.** At the very end, the repo is cloned into a fresh temporary directory, installed from scratch, and the entire verifier suite is run against the clean checkout — proving the build reproduces from nothing and `.gitignore` didn't swallow anything required.
4. **Guaranteed notification.** Every run ends with exactly one phone ping (see [Notifications](#notifications)) — success, halt, or crash. Silence is impossible by construction, so "no news" never means "check the terminal."

Throughout, the filesystem and git are the agent's shared memory: every durable decision becomes a file or a commit, never something held only in a session's context. Workers are fresh `claude -p` processes that read their instructions from disk (`PLAN.md`, `CLAUDE.md`) and leave their evidence on disk.

## Components

This is a standard Claude Code plugin. Its pieces:

| Path | What it is |
| --- | --- |
| `.claude-plugin/plugin.json` | Plugin manifest (name, version, author). |
| `commands/build.md` | The `/build` slash command — the **orchestrator**. Holds the plan and all judgment; delegates implementation to fresh worker sessions and reads results back from disk. Never writes product code itself. Also carries, embedded verbatim, the two guardrail hook scripts it deploys into every target repo (see below). |
| `agents/verifier_builder.md` | Subagent invoked once per phase during scaffolding. Encodes acceptance criteria the orchestrator supplies into a single frozen pass/fail verifier script. An encoder, not a judge — it never decides what "correct" means, and it must confirm each verifier fails cleanly on the still-empty repo. |
| `agents/repo_scan_clean.md` | Read-only subagent invoked after a phase verifies. Diff-scoped (looks only at the phase's uncommitted changes) and returns proposed dead-file deletions and `.gitignore` additions to the orchestrator. Makes zero changes itself and never proposes touching `verifiers/`. |
| `agents/finalizer.md` | Subagent invoked once in Phase 3. Judges whether the project is research or engineering and writes the target repo's `SUMMARY.md` and `README.md`, grounded strictly in the `results/` trail and what exists on disk. Proposes `.gitignore` changes rather than applying them. |
| `skills/notify/` | The `notify` skill — pushes a phone notification via [ntfy](https://ntfy.sh) on a full success (attaching `SUMMARY.md`) or a halting failure (attaching a short digest). `SKILL.md` is git-ignored because it carries a private ntfy topic; `skills/notify/README.md` explains how to recreate it. |
| `hooks/hooks.json`, `hooks/completion_ping.sh` | Plugin-level `Stop` hook — the dead-man's switch. Fires when the orchestrator session ends and pings "ended unexpectedly" **unless** the notify skill already recorded a controlled ending. |

### Two kinds of hooks — don't confuse them

- **Plugin hooks** (`hooks/` here) load only in the orchestrator's own session. There is exactly one: the completion ping.
- **Target-repo guardrail hooks** (`verifier_freeze.sh`, `auto_verify.sh`) do **not** live in this repo as files. Their full script bodies are embedded inside `commands/build.md`, and the orchestrator writes them into each target repo's `.claude/` during Phase 1. This is deliberate: workers are separate `claude -p` processes that never load this plugin, so the guardrails must live in the target repo where every session — orchestrator and workers alike — picks them up.

## Requirements

- **Claude Code** CLI.
- **git** — the target repo's history *is* the build's memory and restore mechanism.
- **`jq`** — the deployed guardrail hooks parse hook JSON with it. The orchestrator's preflight checks for it and refuses to start without it.
- *(Optional)* An [ntfy](https://ntfy.sh) topic on your phone for notifications.

## Installation

Clone the plugin anywhere and point Claude Code at it with `--plugin-dir`:

```bash
git clone <this-repo> ~/plugins/agentic-workflow-plugin
```

Nothing in the plugin assumes where it is installed. The `/build` command is manual-invocation only (`disable-model-invocation: true`) — the model will not trigger it on its own.

### Notify skill setup (optional)

`skills/notify/SKILL.md` carries a private ntfy topic and is **git-ignored** on purpose — the topic name is the only secret on ntfy, so it stays untracked. On a fresh clone the skill therefore doesn't exist yet: see `skills/notify/README.md` for what it must contain, and set the same topic in `hooks/completion_ping.sh` — the crash ping and the success/failure pings must land on the same channel. Without the skill, builds still run; you just get no phone pings (and the Stop hook will report every ending as unexpected).

## Usage

Invoke the builder with a description of what to build:

```
/build A RL environment for Linear Algebra problems
```

The orchestrator runs unattended — it cannot ask questions (`AskUserQuestion` is disallowed). When it hits ambiguity it makes a judgment call, records the decision in `PLAN.md` or the phase's results file, and proceeds.

### Phase 1 — Scaffolding

1. **Preflight**: confirm `jq` exists; clear any stale `.notified` marker from a previous run.
2. Analyze the request into ordered phases and write `PLAN.md`, each phase with a status of `Pending / In-progress / Verified / Failed`.
3. Write **all** verifiers up front via `verifier_builder` — one frozen script per phase under `verifiers/`, each verified to fail cleanly against the still-empty repo.
4. Write a stack-appropriate `.gitignore` (which must also ignore the run-state files below) and a `CLAUDE.md` of conventions every worker must follow.
5. Deploy the guardrail hooks into the target repo: `.claude/settings.json` plus the two scripts, written verbatim from `build.md` and made executable.
6. `git init` (if needed) and commit the scaffold. Pushing happens only if a remote is configured; otherwise it's noted in `PLAN.md` and skipped.

### Phase 2 — Work loop (per phase, in order)

1. Mark the phase `In-progress` and write its number to `.current_phase` so the auto-verify hook knows which verifier to run.
2. Spawn a **fresh headless worker**: `claude -p "Implement phase <N> described in PLAN.md..." --dangerously-skip-permissions --add-dir .`. The worker's `PostToolUse` hook re-runs the phase verifier after each edit, feeding failures straight back into the worker's context so it self-corrects.
3. Verify the **full suite so far** — this phase's verifier plus every earlier one.
4. On success, write `results/phase<N>_results.md` (context, motivations, what was done and why, results, attempt count), then commit **"Implemented phase \<N\>"** — the pre-cleanup restore point.
5. Cleanup: `repo_scan_clean` returns proposals; the orchestrator applies the ones it agrees with, re-runs the suite, and rolls back to the implementation commit if cleanup broke anything. Then commit **"Cleaned up phase \<N\>"** and mark the phase `Verified`. Two commits per phase, always.
6. Re-read `PLAN.md` and the phase's results; revise the plan if this phase invalidated any assumption.

Each phase has a **retry budget of 3** (verifier output fed back on each retry). On exhaustion the orchestrator writes `FAILURE_phase_<N>.md`, resets the working tree to the last good commit, marks the phase `Failed`, sends the failure notification, and **stops** — it never builds past a failed dependency.

### Phase 3 — Finalization

1. Final whole-diff cleanup (same proposal/apply/re-verify discipline as Phase 2).
2. `finalizer` writes the target repo's `SUMMARY.md` (what came of it) and `README.md` (how to use it), grounded in the `results/` trail; the orchestrator sanity-checks both against reality.
3. **Fresh-clone acceptance check**: clone into a temp directory, install from scratch, run the entire verifier suite; append the outcome to `SUMMARY.md`.
4. Commit, push if possible, and send the success notification.

### What a finished build leaves behind

In the target repo: `PLAN.md`, `CLAUDE.md`, the frozen `verifiers/`, a per-phase `results/` trail, `SUMMARY.md`, `README.md`, any `FAILURE_phase_*.md`, and a git history with two commits per phase.

## Run-state files

Two tiny gitignored flag files in the target repo let the stateless hook scripts and the notifier coordinate:

- `.current_phase` — the number of the phase currently being implemented; the auto-verify hook reads it to pick the right verifier.
- `.notified` — its existence means a controlled success/failure notification was already sent, so the Stop hook stays silent. Cleared at the start of every run.

## Notifications

Three pings, all to the same ntfy topic — every run ends in exactly one of them:

| Ping | Sent by | When |
| --- | --- | --- |
| ✅ Build complete | `notify` skill | Whole suite verified; `SUMMARY.md` attached. |
| ❌ Build halted at phase N | `notify` skill | Retry budget exhausted; short digest attached, pointer to `FAILURE_phase_<N>.md`. |
| ⚠️ Ended unexpectedly | `hooks/completion_ping.sh` (Stop hook) | The orchestrator session ended without either of the above — the dead-man's switch. |

Notifications are best-effort: a failed `curl` is noted and skipped, never retried in a loop, and never treated as a build failure.

## Running it unattended

The workflow is designed to run headless. A typical invocation:

```bash
caffeinate -i nohup claude -p "/build create an RL environment for chemistry problems" \
  --plugin-dir ~/plugins/agentic-workflow-plugin \
  --dangerously-skip-permissions \
  --output-format stream-json --verbose > build.log 2>&1 &
```

Workers spawned by the orchestrator run as separate `claude -p` processes; they do **not** inherit the orchestrator's permissions or loaded plugin, so each worker command passes `--dangerously-skip-permissions` explicitly and is pointed at `PLAN.md` and `CLAUDE.md`.

> Note: `--dangerously-skip-permissions` lets the agent act without prompts. Run it only on work you're comfortable executing unattended.

## Author

Patrick Ming
