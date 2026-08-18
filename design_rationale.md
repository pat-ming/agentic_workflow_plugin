# Agentic Builder — Design Rationale (the "why")
 
This document captures the reasoning behind every significant choice in the agentic-builder plugin. The files themselves say *what* the system does; this says *why* it's built that way, so a future session (or a future you) can change things without re-deriving the logic or re-breaking things we already fixed.
 
## What the plugin is
 
You invoke `/build <what to build>` and an orchestrator autonomously builds a whole project end-to-end — plan, verifiers, phase-by-phase implementation, cleanup, finalization — while you're away for hours. The plugin encodes *your development style* so the output looks like something you'd have built. It runs unattended, notifies you when it finishes or fails, and leaves a reproducible git history behind.
 
The whole run is one command:
 
```bash
caffeinate -i nohup claude -p "/build <prompt>" \
  --plugin-dir <plugin> --dangerously-skip-permissions \
  --output-format stream-json --verbose > build.log 2>&1 &
```
 
## The core principle: delegate the body, keep the judgment
 
The tension we started from: subagents save context, but a subagent only returns its *result*, not everything it learned. So "make everything a subagent" would throw away understanding.
 
The resolution is that in this design the **filesystem and git are the return channel**, not the conversation. A worker's useful output becomes code on disk, a commit, a passing verifier, a `results/` file. The stuff a subagent *can't* hand back — its dead ends, its wrong turns — is exactly the stuff you *want* discarded. So the lossiness is a feature.
 
That gives a two-part test for "should this be delegated?": (1) does it burn a lot of tokens to produce a small, checkable result, and (2) can everything the next step needs be written to a file? If both, delegate. The thing that fails part (2) — and therefore stays with the orchestrator — is the evolving judgment about the plan itself. That can't be cheaply serialized because it's a running model of the whole project, not a discrete artifact. So: **delegate the body, keep the judgment.**
 
## Why the orchestrator is a command, not an agent
 
The orchestrator is the one thing that must hold judgment (the plan, plan-adaptation, retry-vs-fail). That belongs at the root of the tree, and the root is the main session. A slash command's body is injected into the main conversation and runs there with full tool access — so `/build` *makes the main session become the orchestrator*, which is exactly the "give it a prompt and it runs" entry point we wanted.
 
Subagents *can* now nest (up to ~3 levels in current Claude Code), so an orchestrator-as-agent would technically work — but it would sit at depth 1, spending nesting budget and burying its reasoning behind a single returned summary, losing the live plan-adaptation view. No upside. Command it is.
 
## Why the implementer is `claude -p`, not a Task subagent
 
The per-phase implementer does heavy mutation and benefits from a *fresh* context each phase. Running it as an out-of-process `claude -p` worker gives isolation, a clean context per phase, and — importantly — sidesteps the subagent nesting-depth limit entirely, because each `claude -p` is a brand-new root session. Workers coordinate with the orchestrator purely through git and the repo. This is why the implementer is *not* an `agents/` file: it's a process, not an in-session subagent.
 
## The agents are leaves — and the interface/implementation split
 
`verifier_builder`, `repo_scan_clean`, and `finalizer` are Task-tool subagents: read-heavy or well-scoped work that returns a compact result. The rule for wiring them in `build.md` is the caller/callee contract from ordinary code: the orchestrator specifies the *call site* (which agent, what to pass, what it returns) but never the agent's *internals*. The agent's method lives in its own file, as its system prompt. Duplicating an agent's behavior into `build.md` would create two sources of truth that drift apart.
 
A subagent starts with a **fresh context window** — it does not inherit the orchestrator's conversation. Context reaches it through exactly three channels: its own file body (static role), the spawn prompt (call-specific context the orchestrator hands over), and files it reads itself (durable shared state like `PLAN.md`/`CLAUDE.md`). The practical rule: put *call-specific* facts in the spawn prompt; let the agent read *shared* state from disk. If a piece of context is in neither the prompt nor a file the agent reads, it does not exist for that agent. Inheritance is never the answer.
 
## Verifiers: why frozen, and why a hook
 
Verifiers define what "correct" means per phase. They're frozen after Phase 1 so the implementing agent can't grade its own homework — can't edit a verifier to make a failing phase "pass." That's reward-hacking prevention.
 
The freeze is a **hook**, not a rule in `CLAUDE.md`, because a hook is *deterministic* and *un-bypassable*: a PreToolUse hook that returns a deny decision blocks the action even under `--dangerously-skip-permissions`. A CLAUDE.md instruction is a request the model can rationalize around; a deny-hook is a lock. This is the single most important reason hooks exist in this project.
 
## The freeze location saga (and why "Option A" won)
 
The workers that do the editing are separate `claude -p` processes that don't load the plugin, so a *plugin* hook never fires in them — and the workers are exactly where a verifier edit would happen. So the freeze has to reach the workers.
 
We considered making it a plugin feature loaded into workers via `--plugin-dir` ("Option B"). That fails portability: `${CLAUDE_PLUGIN_ROOT}` only resolves inside config files (not in a command body or the shell), there's no documented way for a running session to discover its own plugin's install path, and `claude -p` has no "load plugin by name" flag. So the orchestrator can't portably tell workers where the plugin lives; a hardcoded path breaks on another machine.
 
The portable answer is **the orchestrator writes the freeze itself, to a path it controls** — i.e., into the target repo's `.claude/settings.json` + `.claude/hooks/` ("Option A"). Workers pick it up simply by running inside the repo (`--add-dir .`), with zero knowledge of where the plugin lives. Everything is relative and self-contained, so it runs identically on any machine. The freeze *content* is authored once (embedded verbatim in `build.md`), and the orchestrator deploys it each run — so it's "write once in the plugin" *and* portable. Embedding it verbatim (rather than "write the scripts if they don't exist") also makes the security-critical logic deterministic instead of re-derived by the model each run.
 
A neat consequence of Option A's ordering: the freeze is installed in Phase 1 *after* the verifiers are created, so it never blocks their creation — no "seal" sentinel needed. (Option B would have needed one, because a plugin hook is active from the start and would block `verifier_builder` from writing the very verifiers it's meant to create.)
 
## Two commits per phase
 
Each phase makes an **implementation commit** ("Implemented phase N") and a **cleanup commit** ("Cleaned up phase N"). One commit isn't enough: cleanup (dead-file deletion) can break something, and the recovery is "revert to the pre-cleanup state." That restore point has to be a commit that *already contains this phase's verified work* — otherwise reverting throws the phase away back to the previous phase. So the implementation commit exists specifically to be that restore point.
 
## `results/` is the trail; `NOTES.md` was dropped
 
Each successful phase writes `results/phaseN_results.md` (context, motivation, how, why, results, attempt count). This is the fix for "a subagent doesn't return what it learned": the worker externalizes its findings so `finalizer` can build a real `SUMMARY.md` from them rather than reconstructing history from commits. We originally also had a `NOTES.md`; it was redundant with `results/`, so we removed it — one canonical trail, no drift.
 
## `verifier_builder`: encoder, not judge
 
The orchestrator decides *what success means* for each phase; the agent only *encodes* that into a runnable pass/fail script. If the agent decided the criteria itself, it would be setting its own bar — the exact reward-hacking the freeze guards against. It's also required to write verifiers that FAIL cleanly on the empty pre-implementation repo, so a later "pass" actually means something.
 
## `repo_scan_clean`: propose, don't act
 
It's read-only and returns its deletion/`.gitignore` proposals as its *response text* rather than writing a `proposals.md` file. Two reasons: a written proposals file is itself a stray artifact (the next scan would flag it), and keeping the file-writing authority with the orchestrator means one place owns repo mutations. It's scoped to the diff since the last commit so the build doesn't re-scan the whole tree every phase.
 
## `finalizer`: write docs, propose config, stay grounded
 
It *writes* `SUMMARY.md`/`README.md` directly (durable new docs, low risk) but only *proposes* `.gitignore` changes (config that affects what's committed — that authority stays with the orchestrator). Its hard rule is traceability: everything it writes must ground in `results/` or the repo, and if a phase failed it must say so rather than claim success. Without that, a finalizer for a research project will happily hallucinate benchmark numbers.
 
## Flag files: filesystem coordination for stateless processes
 
`.current_phase` (holds the current phase number) lets the stateless `auto_verify` hook know which verifier to run — the orchestrator writes it before each phase, the hook reads it. `.notified` (existence = a controlled notification was sent) lets the completion hook avoid double-notifying. These are the "filesystem is shared memory" principle shrunk to a single number and a single bit, for processes that can't share memory any other way.
 
Both live in the **target repo**, never the plugin. The plugin is stateless tooling reused across hundreds of builds; per-run state in the plugin would let two concurrent builds clobber each other. General rule: **plugin repo = the "how" (scripts, agents, command); target repo = the "what happened this run" (PLAN.md, verifiers/, results/, flag files, commits).** Both flag files are gitignored in the target repo.
 
## Hooks: structure and placement
 
A hook is two pieces — a JSON config entry (event → matcher → command) and the script it calls — not a self-contained file like an agent. Config is centralized (a `hooks` key), not one-file-per- hook. Placement follows who needs to fire it:
 
- **`verifier_freeze` (PreToolUse) and `auto_verify` (PostToolUse)** must fire in *workers*, so they're deployed into the target repo's `.claude/` (Option A). They use `${CLAUDE_PROJECT_DIR}`.
- **`completion_ping` (SessionEnd)** must fire only for the *orchestrator*, once, when the session actually terminates — not per worker, and not per turn (the `Stop` event fires every time the agent finishes responding, which is why it's the wrong event here). So it lives in the plugin's `hooks/hooks.json` (workers don't load the plugin, so they never trigger it) and additionally gates on `.current_phase` existing, so only a session with a build in flight can raise the alarm. It uses `${CLAUDE_PLUGIN_ROOT}`.
That `${CLAUDE_PROJECT_DIR}` vs `${CLAUDE_PLUGIN_ROOT}` difference is the whole portability story in one line.
 
## Notifications and the dead-man's switch
 
Claude Code can't natively text/email, but hooks and Bash can `curl` anything, so notification is just "run a curl at the right moment." We chose a **push service (ntfy)** over SMS/email: no carrier, no per-message cost, no phone number, one-line `curl`, reaches the phone as an app notification. (SMS via Twilio and iMessage via `osascript` were considered; iMessage scripting is fragile — TCC permission prompts, Apple breaking it across releases, and it only works on your own signed-in Mac — so it's not reliable for unattended runs.)
 
The three endings map to three notifications: controlled success (✅, from the notify skill), controlled failure (❌, from the notify skill), and *uncontrolled death* (⚠️, from the SessionEnd hook). The SessionEnd hook can't tell a clean finish from a crash — both look like "session ended" — so the notify skill drops `.notified` after it fires, and the hook stays silent if that marker exists. `.notified` is touched even if the `curl` failed, because it records that the ending was *controlled*, not that the push was delivered; the dead-man alert is for crashes, not missed pushes. Both the notify skill and `completion_ping.sh` read the topic from `NTFY_TOPIC`, so all three pings land on the same channel with nothing hardcoded.
 
## Autonomy mechanics (how it actually runs unattended)
 
`/build` in headless `-p` mode is both the trigger and the prompt. `--dangerously-skip-permissions` stops it halting on permission prompts — and critically, that flag does **not** inherit to child processes, so every `claude -p` worker spawn must pass it explicitly. `caffeinate`/`nohup` keep the machine awake and the process alive after you close the laptop. We deliberately do **not** set `--max-turns`: termination safety comes from the *design* (retry budget of 3, `FAILURE_*.md` + last-good-commit fallback, "never loop indefinitely"), not a turn cap. Because it runs with broad unsupervised power, run it in a dedicated directory or container, not your home folder.
 
`AskUserQuestion` is disallowed and there's an explicit "never block on questions" rule: an unattended run that asks a question hangs forever waiting for an answer nobody's there to give.
 
## Why skills mostly sit out
 
This is a **command + agents + hooks** project. The auto-invoked, "Claude loads it when relevant" flavor of skills has no role here because the orchestration is deliberately explicit and deterministic — named agents at named steps, not discovery. (The `/build` command and `/notify` are technically skills in the merged commands-are-skills model, but that's the manual-invocation kind.) Skills are the right tool for on-demand know-how; this workflow isn't that shape. Worker style is carried by `CLAUDE.md` instead, which is simpler than a skill and always-on.
 
## Small but sharp lessons
 
- **Unknown manifest keys are silently ignored.** A `decription` typo in `plugin.json` means no description at all, with no error. Run `claude plugin validate --strict`.
- **Agent-name references must match the `name:` frontmatter exactly.** `verifiers_builder` vs `verifier_builder`, `repo_scan_cleaner` vs `repo_scan_clean` — silent misfires.
- **`Task` is the Claude Code subagent tool** (`Agent` is the name on other surfaces).
- **`jq` is a dependency** of the deployed hooks — Phase 1 preflight checks for it.
- **No emoji in filenames** (shell-escaping and cross-platform breakage) — emoji only in notification titles/bodies.
- **Grant a tool for what a component actually does.** A skill/agent whose action is a `curl` needs `Bash`; one that writes a file needs `Write`. Missing grants stall outside bypass mode.
## Component map
 
- `.claude-plugin/plugin.json` — manifest.
- `commands/build.md` — the orchestrator (holds all judgment); embeds the freeze/auto-verify
  scripts + settings for Phase 1 to deploy into the target repo.
- `agents/verifier_builder.md` — encodes success criteria into frozen verifier scripts.
- `agents/repo_scan_clean.md` — read-only per-phase cleanup; returns proposals.
- `agents/finalizer.md` — writes SUMMARY.md/README.md from `results/`; proposes `.gitignore`.
- `skills/notify/SKILL.md` — push notification on controlled success/failure; touches `.notified`.
- `hooks/hooks.json` + `hooks/completion_ping.sh` — orchestrator-only SessionEnd hook (dead-man's switch).
- (deployed into the target repo at runtime) `verifier_freeze.sh`, `auto_verify.sh`, `.claude/settings.json` — the worker-facing guardrails.
## Open items / how to validate
 
Run the audit prompt (static check of components + cross-file consistency), then a real smoke test — `/build a tiny CLI todo app` — because a static audit can't tell you it actually runs. Sync the ntfy topic between the skill and `completion_ping.sh`, make the `finalizer` `results/`-only edit if any `NOTES.md` reference lingers, and delete `verifier_freeze.sh`/`auto_verify.sh` from the plugin's `hooks/` (they belong embedded in `build.md`).