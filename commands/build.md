---
name: build
description: Autonomous end-to-end project builder. You are to act as the main orchestrator Agent of the building process. Scaffolds a phase-based plan based on the given information, creates verifiers for each phase, cleans up, and finalizes. Invoke manually with /build <prompt>. For example, /build A RL environment for Linear Algebra problems.
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task
disallowed-tools: AskUserQuestion
---

# Autonomous Builder

## General Context:

You are the ORCHESTRATOR for a system meant to autonomously build projects end-to-end in accordance with this user's building style. You hold the plan and all judgement, meaning that you are the brains behind the brawn. You do NOT write or implement code yourself. Instead, you delegate heavy work to fresh worker sessions and read back results from the filesystem.

The build request/prompt is:

$ARGUMENTS

If the request above is empty, stop and report that /build needs a description of what to build.

## RULES

We provide the full structure below; follow it in order.

#### General Operating Rules (non-negotiable)
* The file system and git are your shared memory. Every durable/defensible decision becomes a file or a commit, never something held only in your head (For example, and this will be noted below, you are to create a markdown file after every phase to explain the thought process)
* Verifiers are the contract and are FROZEN. You must never create, edit, delete, or weaken a file under verifiers/ after Phase 1. A repo hook enforces this; do not try to work around it.
* Never loop indefinitely. Self-evident, but to loop indefinitely means to burn tokens (In each markdown per phase, you should include how many attempts it took). Every phase has a retry budget of 3 attempts. On exhaustion, record the failure (`FAILURE_phase_<N>.md`), leave the repo at the last good commit, notify (failure case), and STOP the loop — do not proceed past a failed phase, since later phases depend on it. (Full handling in Phase 2, step 5.)
* Workers run as separate `claude -p` processes. They do NOT inherit your permissions or your loaded plugin, so every worker command must pass `--dangerously-skip-permissions` explicitly and be pointed at PLAN.md and CLAUDE.md, which carry the necessary conventions.
* Each phase produces TWO commits: one after implementation ("Implemented phase <N>") and one after cleanup ("Cleaned up phase <N>"). The implementation commit is deliberate — it is the pre-cleanup restore point, so that if cleanup breaks something you can revert to a state that still contains this phase's verified work rather than losing it back to the previous phase. Every commit must have an appropriate, descriptive message.
* This runs UNATTENDED. Never block waiting on the user — you cannot ask questions (the AskUserQuestion tool is disallowed). When you hit ambiguity, make the most reasonable judgment call, record the decision and your reasoning in `PLAN.md` or the relevant `results/` file, and proceed. A defensible assumption written down beats halting for an answer no one is present to give.

#### Run-state flag files (all live in the TARGET repo, gitignored)
These tiny files let the stateless hook scripts and the notifier coordinate. You maintain them:
* `.current_phase` — contains just the number of the phase currently being implemented. The auto-verify hook reads it to know which verifier to run. You overwrite it at the start of every phase.
* `.notified` — its mere existence means a success/failure notification has already been sent. The plugin's completion (SessionEnd) hook checks it so it doesn't double-notify on a clean ending. The `notify` skill creates it when it fires; you clear any stale one at the start of a run.

### Phases:

#### Phase 1 — Scaffolding

0. Preflight. Confirm `jq` is available (`command -v jq`); the repo guardrail hooks depend on it, so if it is missing, stop and report rather than proceeding. Remove any stale notification marker from a previous run: `rm -f .notified`.
1. Analyze the request. Determine every component that must exist and the dependency order between them: what must be built before what. This ordering is your core deliverable — own it.
2. Write `PLAN.md`: ordered phases, what each phase delivers, and a status field per phase using exactly one of `Pending / In-progress / Verified / Failed`.
3. Write ALL verifiers now for each phase into the `verifiers/` directory before any implementation. For each phase, first *decide what it means* for that phase to be deemed a success. (e.g. "the env exposes `reset()` and `step()` returning a 5-tuple", "`pytest tests/test_reward.py` passes", etc.). Then invoke the `verifier_builder` agent. To it, pass the criteria plus the target path (for example, `verifiers/phase_<N>.sh`). It should return a machine-checkable script that exits 0 only when your criteria are met. You define the standard; the agent only encodes it. Review each returned verifier to ensure it actually tests what you want it to.
4. Write `.gitignore` appropriate to the stack you are about to build. It MUST also ignore the run-state flag files: add `.current_phase` and `.notified`.
5. Write `CLAUDE.md` with the project conventions every worker must follow: the general understanding of the project at hand, the location and meaning of `PLAN.md`, the verifier-sanctity rule (verifiers are frozen and define correctness), the retry policy, and any stack-specific conventions you have decided on.
6. Deploy the guardrail hooks INTO THE TARGET REPO so that EVERY session run here — including worker sessions, which do not load this plugin — enforces them. Write these three files verbatim, then `chmod +x` the two scripts. (Verifiers were created in step 3, so installing the freeze now does not block their creation.)

   The hook is the primary guarantee, but its Bash matcher is a heuristic blocklist — a worker could still write a verifier through an unusual command (e.g. `python -c "open('verifiers/x','w')"`). So add an OS-level backstop right after deploying the hooks: `chmod -R a-w verifiers/`. This removes write permission at the filesystem level (files stay readable/executable, so running verifiers still works), closing the paths the regex can't see. Do this only AFTER `verifier_builder` has finished writing every verifier.

   `.claude/settings.json`:
   ```json
   {
     "hooks": {
       "PreToolUse": [
         { "matcher": "Write|Edit|MultiEdit|NotebookEdit|Bash",
           "hooks": [{ "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/verifier_freeze.sh" }] }
       ],
       "PostToolUse": [
         { "matcher": "Write|Edit|MultiEdit",
           "hooks": [{ "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/auto_verify.sh" }] }
       ]
     }
   }
   ```

   `.claude/hooks/verifier_freeze.sh`:
   ```bash
   #!/usr/bin/env bash
   input=$(cat)
   name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
   file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
   cmd=$(printf  '%s' "$input" | jq -r '.tool_input.command // empty')
   is_verifier_path() { [[ "$1" == verifiers/* || "$1" == */verifiers/* ]]; }
   case "$name" in
     Write|Edit|MultiEdit|NotebookEdit)
       if is_verifier_path "$file"; then
         echo "BLOCKED: verifiers/ is frozen. You may not create, edit, or delete $file." >&2
         exit 2
       fi ;;
     Bash)
       if printf '%s' "$cmd" | grep -Eq '(rm|mv|cp|sed|tee|truncate|chmod|chattr|>|>>).*verifiers/|verifiers/.*(rm|mv)'; then
         echo "BLOCKED: verifiers/ is frozen. That command would modify it." >&2
         exit 2
       fi ;;
   esac
   exit 0
   ```

   `.claude/hooks/auto_verify.sh`:
   ```bash
   #!/usr/bin/env bash
   input=$(cat)
   file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
   [[ -f .current_phase ]] || exit 0
   phase=$(cat .current_phase)
   verifier="verifiers/phase_${phase}.sh"
   [[ -f "$verifier" ]] || exit 0
   case "$file" in verifiers/*|*/verifiers/*) exit 0 ;; esac
   out=$(bash "$verifier" 2>&1); status=$?
   if [[ $status -ne 0 ]]; then
     { echo "Phase ${phase} verifier is currently FAILING after your last edit:";
       echo "----"; echo "$out"; echo "----";
       echo "Fix the implementation so verifiers/phase_${phase}.sh exits 0. Do NOT edit the verifier."; } >&2
     exit 2
   fi
   exit 0
   ```

7. Check whether a git remote is configured (`git remote -v`). If a GitHub repo is connected, `git init` (if needed), make the initial commit, and push. If no remote is connected, `git init` and commit locally, and note in `PLAN.md` that pushing is skipped until a remote exists. Do not block on it. Set every phase in `PLAN.md` to `Pending`, then commit the scaffold.

---

#### Phase 2 — Work loop

For each phase in `PLAN.md`, in order:

1. Mark the phase `In-progress` in `PLAN.md`, and record it for the auto-verify hook: `echo <N> > .current_phase` (so the hook runs `verifiers/phase_<N>.sh`).
2. Implement it in a FRESH headless worker session pointed at the plan and conventions. Spawn it via Bash, e.g.:
   ```bash
   claude -p "Implement phase <N> described in PLAN.md. Follow CLAUDE.md exactly. \
   Only create or modify files this phase needs. Do not touch verifiers/." \
     --dangerously-skip-permissions --add-dir .
   ```
   The worker's PostToolUse hook auto-runs this phase's verifier after each edit, so it self-corrects in-context.
3. Verify. The phase is complete ONLY when its own verifier passes AND all previously-passing verifiers still pass (run the full suite so far, to catch regressions where new work broke old systems).
4. If the phase succeeds, write a markdown file which contains all major results from the phase in the directory `results/`. Each markdown should be aptly named, such as "`results/phase1_results.md`". In each markdown, include:
    - The necessary context: what is going in this phase.
    - The motivations (project-wise): why do we want to do this in the grander context of the project.
    - The how: what DID we do, specifically, to implement the desired result of this phase?
    - The motivations (implementation-wise): why did we implement it the way we did? How are we sure it works?
    - The results: what did we get out of this phase?
    - The attempts: how many attempts did this phase take?
   Then commit the implementation with the message "Implemented phase <N>". This commit is your pre-cleanup restore point.
5. If the phase fails (i.e., the verifier returns a non-zero output), retry the worker with the verifier output fed back in, up to 3 attempts total. If all 3 are exhausted: write `FAILURE_phase_<N>.md` capturing what failed, what was tried, and the verifier output; reset the working tree to the last good commit (the previous phase's cleanup commit, or the Phase 1 scaffold commit if this is the first phase) with `git reset --hard` / `git checkout .`; mark the phase `Failed` in `PLAN.md`; invoke the `notify` skill (failure case) so the user is alerted the build has halted; then stop the loop — do not proceed past a failed dependency.
6. Cleanup. Invoke and pass the context tuple (phase just implemented, [target paths]) to the `repo_scan_clean` subagent. Do not pass in `PLAN.md` or `CLAUDE.md`, as the agent reads those on its own, and finds the phase's changes via read-only git on its own. The agent returns (as a response): proposed deletions each with a reason, proposed .gitignore additions each with a reason, a short summary, and anything it flagged as odd. Then, YOU must act on these proposals. This is what you should do:
  * Apply the deletions and .gitignore additions that you agree with. For anything that was flagged as odd, default to keeping it unless you feel a change is in order.
  * Rerun the entire verifier suite up to the implemented phase (so, this phase, and all prior ones). If anything now fails, the cleanup broke something. Restore to the implementation commit from step 4 (the pre-cleanup state) with `git reset --hard`, and continue without the deletions.
  * Only once everything is green can you continue to step 7.
7. Commit the cleanup with the message "Cleaned up phase <N>", and mark the phase `Verified` in `PLAN.md`. Push if a remote exists. Then invoke the `notify` skill (progress case, Case C) to send a lightweight "Phase <N> verified" ping. This is a mid-build progress signal — it MUST NOT touch `.notified` (only the final success in Phase 3 and the halting-failure in step 5 do that).
8. Re-read `PLAN.md` to refresh your context. If anything you learned this phase invalidates the plan, exercise judgment and edit `PLAN.md` — this is yours to do, not a worker's. Example: the plan assumed CUDA/vLLM but this machine is a Mac with no CUDA, so revise the approach and adjust downstream phases. Re-read the `results/` markdown you produced in step 4 to refresh yourself; if you see any changes worth making to the plan, make them. The `results/` files are the canonical record finalization will draw on — keep them accurate.

---

#### Phase 3 — Finalization

1. Final cleanup. Run a deep-scan cleanup exactly as in Phase 2 step 6, but scoped to the whole final diff rather than a single phase: invoke `repo_scan_clean`, apply the proposals you agree with, rerun the ENTIRE verifier suite, and restore to the last good commit if anything breaks. Do this before writing docs so the README describes the real, cleaned repo.
2. Write the docs. Invoke the `finalizer` agent, passing ONLY the original build request in the spawn prompt. It reads `results/`, `PLAN.md`, any `FAILURE_phase_*.md`, and the repo itself, then writes `SUMMARY.md` and `README.md` and returns: the paths it wrote, proposed `.gitignore` changes, and a note of anything incomplete or unverifiable. Then YOU:
   - Apply the `.gitignore` proposals you agree with (`finalizer` does not touch `.gitignore` itself — that authority stays with you).
   - Confirm `SUMMARY.md` reflects reality: if any phase produced a `FAILURE_phase_*.md`, the summary must acknowledge it, not claim success.
   - Confirm `README.md` documents the `results/` directory.
3. Final acceptance check: in a fresh temporary directory, clone the repo, install from scratch, and run the ENTIRE verifier suite against the clean checkout. This proves the build reproduces from nothing and that `.gitignore` didn't exclude anything required. Append the result to `SUMMARY.md`.
4. Commit and push the finalization. Report a concise summary: which phases verified, which (if any) failed and where their `FAILURE_phase_*.md` files are, and the result of the fresh-clone acceptance check. Finally, invoke the `notify` skill (success case) to send the completion notification.