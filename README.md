# An agentic builder for personal use.
----------------

With the advent of AI, one-time prompts can be slow when building projects. This project does remove the human aspect of building, as it allows the AI to code autonomously. You may ask what this does differently from `claude --dangerously-skip-permissions`, and I'd argue that while dangerously skip permissions is asking "can the agent act without asking?", this project is more "how do I *know* what the agent did is correct without checking myself". Slightly different. And enough of an optimization in my personal life (as I like to build lots of random things) that creating this workflow agent is worth it. 

## Introduction

At it's core, this is a personal agent that I built for my own purposes. I have a specific way I like to build, and this workflow is meant to mimic it. It is an unsupervised, phase-based agentic workflow for building. 

Core loop: **Plan -> Implement -> Verify -> Clean -> Commit -> Next**

## Phases:

#### Phase 1: Scaffolding

1. Take the prompt, and analyze all dependencies and determine a logical order of work. Figure out what needs to be done before it has to be done.
2. Write the plan to a variable `PLAN.md`. Ordered phases, what each phase delivers, and a status field per phase (something like `Pending / In-progress / Verified / Failed`).
3. Write ALL verifiers now, one per phase (or per subphase, if it is that necessary) into a dedicated `verifiers/` directory. Each is an independent script or terminal check (RLVR-style: pass/fail, machine-checkable).
    * Verifiers are written before any impleentation exists, by the scaffold phase. 
    * Verifiers are frozen: a `PreToolUse` hook blocks any edit or delete under `verifiers/` for the rest of the run. This implementing agent must never be able to grade its own homework or move the A+ cutoff (to prevent reward hacking)
4. Write a `.gitignore` now. Between each phase, and especially before every commit, the agent must know to check the state of the files and update a .gitignore. 
5. Write or append information to a `CLAUDE.md` with project conventions. I.e., the verifier-sanctity rule, the location of `PLAN.md`, etc. 
6. Run `git init` + initial commits and pushes. This step assumes that a github repository is connected, which should be checked.

#### Phase 2: Work-loop

1. For each phase in `PLAN.md`, the following steps should be done:
2. Implement the phase in a fresh headless session (`claude -p`), pointed at `PLAN.md` and `CLAUDE.md`. A `PostToolUse` hook auto-runs the current phase's verifiers after every file edit so failures surface immediately in-context. 
3. Verify. This step is only done when its verifiers pass, plus all previous verifiers (redundancy check to make sure new edits didnt kill old systems).
4. Check for failures. Each phase will have a retry budget (for now, let's say 3 attempts). If we burn through all 3 attempts, write a `FAILURE_phase_X-Y.md` file (What failed, what was tried, verifier ouput). Leave the repo at the last good commit, never loop indefinitely.
5. Clean up any changes made. Let a sub-agent (read-heavy, isolated context) to deep-scan the repo and propose dead scripts for deletion. Delete, then rerun the verifier suite. (Can also make it so that this sub-agent only reads recent changes between commits, as it may be redundant). If anything breaks, can restore to a previous good commit `git checkout`. 
6. Commit any changes. One per phase. 
7. After each phase, recheck `PLAN.md` to refresh context. Additionally, if while building we come across anything that would make us change our minds about what the plan, make a judgement call and modify `PLAN.md` if necessary. For example, if you wanted to run vLLM in the plan, but find that we are on a Mac and don't have CUDA, then fix the plan.

#### Phase 3: Finalization

1. Write a `SUMMARY.md` separate from `README.md`. Highlight major results. Judge project type first: research projects get a results section (findings, numbers, plots, things that don't really live in a `README.md`). Pure engineering projects may be reduced to a couple lines of findings.
2. Final deep scan + cleanup (like in step 2.5)
3. With this final deep scan in mind, write a `README.md` to be displayed on the repository. Also, reconcile `.gitignore` with what exists now.
4. A final verifier. In a fresh directory, clone the repo, install from scratch, and run the full verifier suite. 

## Directory Structure: