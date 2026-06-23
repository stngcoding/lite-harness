# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`dartralph` is a Dart CLI that automates draining a PRD's `ready-for-agent`
GitHub sub-issues: it runs the `claude` CLI per issue, gates each slice
(analyze + scoped tests), then opens one PR per PRD that an independent reviewer
gates as a whole. It is a
Dart port of `legacy/my-ralph.sh`. The harness itself is a Dart package, but it
is **run from inside a target repo clone** and its gates assume that target is a
Flutter project (`fvm flutter analyze` / `fvm flutter test`).

## Commands

```sh
dart pub get                       # install deps
dart test                          # run all tests
dart test test/verdict_test.dart   # run one test file
dart test -n "the last verdict"    # run tests matching a name
dart analyze                       # static analysis (lints/recommended)
```

Run the harness against a target repo (from inside that repo's clone):

```sh
dart run ~/lite-harness/bin/dartralph.dart --dry-run   # preview order, change nothing
dart compile exe bin/dartralph.dart -o build/dartralph   # standalone binary
```

Key flags (all also read env vars): `--repo owner/name` (REPO),
`--state open|closed|all` (STATE), `--base <branch>` (BASE, default `dev`),
`--model <model>` (MODEL, default `opus` — the top implementer model /
escalation ceiling; cheap lanes start below it and climb on retries), `--issue
N`, `--once`, `--dry-run`.

## Architecture

The entrypoint `bin/dartralph.dart` parses args, builds a `Config`, wires the
collaborators, and hands off to `HarnessLoop.run()` in `lib/src/loop.dart`. The
public surface is re-exported from `lib/dartralph.dart`.

`HarnessLoop` is the orchestrator and holds all the policy. The class is large,
so its body is split across `loop.dart` and three `part of 'loop.dart'` files —
one Dart library, so the extensions keep full access to the loop's private
state without any field-threading:

- `loop.dart` — the core: construction, `run()`, PRD selection/draining, the PR
  gate (`_maybeOpenPr`), and the stranded-PRD sweep.
- `slice_runner.dart` — the slice lifecycle. Both the sequential drive
  (`_processSub`) and a parallel worker (`_driveWorker`) route through one
  `_runSlice(issue, io)`; the only per-mode differences (git/claude binding,
  `claude`-call retry/cost policy, where narration goes, what pass/fail means)
  live behind the `_SliceIo` seam (`_SeqSliceIo` / `_WorkerSliceIo`). There is
  no longer a second hand-mirrored copy of the lifecycle to keep in sync.
- `worker_pool.dart` — the parallel pool (`_drainParallel`, `_nextReady`,
  `_runIssueInWorktree`, `_mergeAndPrAll`, the dashboard) plus `_Worker` /
  `_WorkerOutcome`.
- `ci_watcher.dart` — the CI fix/handoff helpers (`_runCiFix`,
  `_commentCiHandoff`, the `_CiOutcome` outcomes).

Everything else is a thin, side-effecting wrapper around an external CLI:

- `GhCli` (`github.dart`) — wraps `gh`: list ready issues, read state/comments,
  label, comment, close, open/ready PRs.
- `GitOps` (`git.dart`) — wraps `git`: branch checkout, stash drift, commit,
  tag, reset, push, ahead-count.
- `ClaudeRunner` (`claude.dart`) — wraps the `claude` CLI: `implement` runs
  `claude -p`; `verify` runs `claude --agent diff-verifier`. Both stream
  `stream-json` output. `--agent` is deliberate: it gives the reviewer an
  isolated system prompt, so the independent review does not inherit the target
  repo's `CLAUDE.md` or skill preambles.
- `AgentInstaller` (`agents.dart`) — ships the review agents the `verify` gate
  depends on (`AgentInstaller.bundledAgents`): the `diff-verifier` orchestrator
  plus the two workers its PR pipeline fans out to (`pr-review-lens`, the
  independent panel reviewers; `pr-review-haiku`, the triage/scoring helper). On
  startup (non-dry-run) it writes each bundled `lib/agents/<name>.md` into the
  target repo's `.claude/agents/` *only if absent*, so a fresh clone is never
  silently failed by every gate; a target that ships its own tuned reviewer
  keeps it.
- `ProcessRunner` (`proc.dart`) — the only place that actually spawns processes
  (`run` for buffered, `stream` for line-by-line). All wrappers depend on it,
  which is what makes the loop testable in principle.

Pure, dependency-free logic is isolated into the modules that carry the unit
tests — this is the code to touch carefully:

- `issue.dart` — `Issue` model + parsing of `## Parent` / `## Blocked by`
  sections, `priorityScore` (label → rank), `sortReady`, `slugify`,
  `umbrellaNumbers` (which ready issues are the *parent* of another).
- `claude_stream.dart` — parses `stream-json` lines into `StreamEvent`s and
  renders a live transcript; `StreamRenderer.transcript` is the string the
  verdict is read from.
- `verdict.dart` — `hasPassVerdict`: a transcript passes only if the **last**
  line that is exactly `VERDICT: PASS` (not `FAIL`, not prose mentioning it)
  says PASS. This protocol is load-bearing; the reviewer agent must emit a bare
  verdict line.

### The per-PRD flow (loop.dart)

1. Select the active PRD from the highest-priority *processable* ready issue
   (processable = every `## Blocked by` issue is CLOSED). A parent-less issue
   with no children is its own PRD-of-one. A parent-less issue that *other*
   ready issues declare as `## Parent` is an **umbrella**: it only groups its
   slices and is closed by the PR's `Closes #parent`. `_drainPrd` detects
   umbrellas via `umbrellaNumbers`, never implements them, and drops their
   `ready-for-agent` label (`GhCli.dropAgentLabel`) so they cannot re-enter
   selection. Implementing an umbrella would redo the whole PRD scope once on
   top of every slice.
2. Check out `<parent#>-<slug>` off `origin/<base>` (resume if it exists; park
   uncommitted drift in a stash first).
3. For each processable sub-issue: **Implement** (`claude -p`) → **commit**
   immediately → **gate** (`fvm flutter analyze` + a *scoped* `fvm flutter
   test`). The implement model is chosen by the slice's risk lane
   (`model_ladder.dart`): tiny/normal slices open on Sonnet, high-risk on Opus,
   and each failed retry climbs one rung toward the `--model` ceiling — a cheap
   model takes the first shot, a smarter one is only paid for when a gate fails.
   The model that ran is recorded on the slice's trace. The test gate runs only
   the tests the slice's diff touches —
   `scopedTestFiles` (`test_scope.dart`) maps the changed paths to each changed
   `test/…_test.dart` plus the mirror `_test.dart` of every changed `lib/…dart`
   (`_scopedTestGate` filters those to the ones that exist). So a pre-existing
   red test on base never fails a slice; an empty scope passes (the PR gate is
   the backstop). PASS → close the issue; FAIL → tag `ralph-fail/<n>`, `reset
   --hard` to baseline, relabel `ready-for-human`, comment with log tails.
4. When commits are ahead of base and the PRD has **no open managed subs left**
   (`_maybeOpenPr` re-checks GitHub live — no open issue parented to the PRD is
   still labeled `ready-for-agent`/`ready-for-human`), push, open one draft PR,
   run the **whole suite** here (`fvm flutter analyze` + full `fvm flutter
   test` — the per-issue gates were scoped) plus the PR-level `diff-verifier`
   over the whole diff, mark ready only if the full suite is green **and** the
   review passes. A red base keeps the PR a draft for a human — non-destructive,
   nothing is rolled back here. The gate is live state, not an in-run flag: a
   sub that failed earlier but was since closed no longer blocks the PR. In PR
   mode (`pr-verifier.md`)
   the orchestrator runs the reverse-engineered Anthropic `/code-review`
   pipeline — triage → six independent review lenses (CLAUDE.md, bug scan, git
   history, prior PRs, in-code comments, and a whole-diff **structural** lens)
   fanned out via `Task` → per-issue 0–100 confidence scoring → drop everything
   below 80 → a cited PASS/FAIL. The verdict is reserved for substance plus a
   short, enumerated list of objective CLAUDE.md rules the structural lens
   promotes from nit to block (a file pushed past its stated max length, a
   function widget, a raw asset path, a hardcoded token, a silent catch, an
   inline comment); subjective "code judo" simplifications never block. It still
   ends in the single bare `VERDICT:` line the harness reads. The reviewer also
   emits two surface-don't-gate channels, both parsed in `manual_notes.dart` and
   rendered in `pr_comments.dart`: `MANUAL:` lines for acceptance criteria the
   gates cannot settle from the diff (UI, real-device perf, external-service
   behavior) → `manualNotes`/`manualSection` as an unchecked checklist; and
   `STRUCTURAL:` lines for the structural lens's subjective simplifications →
   `structuralNotes`/`structuralSection` as a "Maintainability review" section.
   Both surface on the draft PR for the human — never gated on.
5. **CI watch + auto-fix** (`--watch-ci`, default on). The local gates are a
   `fvm flutter` build; the PR's GitHub Actions can still fail what that build
   never runs (a different OS, golden/screenshot tests, integration suites,
   codegen, a stricter analyzer). So when the local suite + review are green,
   `_maybeOpenPr` does **not** mark the draft ready yet — `_watchCi` follows the
   PR's remote CI to a conclusion first. It polls `gh pr view` (`prCiStatus` →
   the pure, unit-tested `parseCiStatus`) with backoff (30s/60s/120s via
   `ciPollInterval`) and a 60s grace before trusting an *empty* rollup, so a PR
   whose checks have not registered yet is not misread as having none.
   CI **green** (and the branch not `CONFLICTING`) → mark ready. **No checks**
   after the grace → a repo without CI: mark ready off the local verdict (the
   historical behavior; `--watch-ci=0`/`WATCH_CI=0` forces this path outright).
   CI **failing** → fetch `gh run view --log-failed` (`ciFailedLogs`), feed the
   tails to the `ci-fixer` agent (`ci-fixer.md`), commit its fix, **re-run the
   local gates** (a CI fix must not regress them), re-push, and resume the
   watch — up to `--max-ci-fixes` (default 3) rounds. Past the fix budget, a
   local-gate regression, a no-op fix, a secret leak, a push failure, a base
   **conflict**, or `--ci-timeout` (default 30m) elapsing all leave the PR a
   draft with a handoff comment (`FrictionKind.ciFail` traced). Nothing is ever
   rolled back here — the watch only withholds the auto-ready signal.
6. **Stranded-PRD sweep.** After the ready queue empties, `_shipStrandedPrds`
   walks local `<parent#>-<slug>` branches and PRs any whose parent is still
   OPEN, has no open managed subs, commits ahead, and no existing open PR. This
   catches PRDs whose last failed sub was resolved (re-run or human close) after
   the PRD had already fallen out of selection — without it, that branch never
   gets a PR. Idempotent, so a looping harness never re-opens or spams.

### Parallel mode (`--concurrency` > 1, default 2)

The flow above is the **sequential path** (`concurrency == 1`), kept verbatim.
When `--concurrency` is 2..4, `run()` forks into `_drainParallel` instead — a
**single-driver, bounded worker pool** whose unit of parallelism is the
*sub-issue*, not the PRD:

- **One driver schedules.** Only `_nextReady` hands out work, called serially
  between `await`s, so the in-flight/handled sets never race (Dart's single
  isolate makes the mutations between two synchronous statements atomic — no
  mutex needed). It picks the highest-priority slice whose every `## Blocked by`
  issue is *satisfied* — CLOSED on GitHub **or** passed earlier this run
  (`_passedThisRun`) — via the pure `eligibleSlices` (`issue.dart`, unit-tested).
- **Worktree per slice.** Each slice runs in `.dartralph/worktrees/ralph-slice/<n>`
  on branch `ralph-slice/<n>` cut from `origin/<base>`, then true-merged with the
  branch of every blocker that passed *this run* (their work is not on base yet);
  a merge conflict is a real integration clash → relabel `ready-for-human`, skip.
  `GitOps` carries a `workingDirectory`, so each worker's `git`/`claude`/`fvm`
  gates are scoped to its worktree. Per-issue output streams to
  `.dartralph/logs/issue-<n>.log`, not stdout. `createWorktree` is **self-healing**:
  a run that was killed (e.g. by a hard limit-out) leaves a stale `ralph-slice/<n>`
  branch + directory, so a plain `worktree add -b` would fail; on a first failure it
  clears the stale worktree/branch/orphan-dir for that exact path and retries once,
  so a crashed run never strands the slice on the next pass.
- **`_driveWorker` shares the slice lifecycle with `_processSub`.** Both call the
  single `_runSlice` (classify → implement → secret-scan → commit → analyze +
  scoped test); the worker passes a `_WorkerSliceIo`, so a terminal pass records
  a `_WorkerOutcome` for the merge phase instead of closing the issue and opening
  a PR inline. N=1 stays untouched because it passes `_SeqSliceIo` to the very
  same method — no second copy to drift.
- **A usage limit checkpoints, it does not pause.** A `claude` rate limit
  (`_callPausing`) throws a *resumable* `ClaudeAbort`. The scheduler stops handing
  out work and lets in-flight workers finish (each on its own retry backoff), then
  `_checkpointAndCleanup` runs *before* the abort unwinds: every PRD with passed
  slices is cherry-picked onto its `<parent>-<slug>` branch and **pushed**, those
  issues are closed, and every leftover worktree (a slice that failed or was
  interrupted mid-flight) is dropped — its issue left `ready-for-agent` to retry.
  The PR is *not* opened here (its `diff-verifier` + full suite would re-hit the
  same limit); it opens on the next run once the PRD drains. The process then
  exits **75** (EX_TEMPFAIL) so a wrapper (cron/launchd/`/loop`) re-runs when the
  window resets and the idempotent harness resumes. Pausing a live pool for a cap
  that can be hours out was fragile — a killed process orphaned worktrees, and the
  next run's `git worktree add` then failed every slice into `ready-for-human`.
  Auth/billing/exhausted-transient still throw a *non*-resumable `ClaudeAbort`
  (exit 2): completed work is checkpointed the same way, but a re-run would fail
  identically, so it does not signal retry-me.
- **Merge phase (`_mergeAndPrAll`).** After the pool drains, each PRD's passed
  slices are cherry-picked in issue order onto its `<parent>-<slug>` branch, then
  the unchanged PR gate (`_maybeOpenPr`: full suite + `diff-verifier` + the CI
  watch of step 5) runs. A cherry-pick conflict — a slice that forked off a base
  missing a sibling's overlapping edit (an overlap the implicit-blocker predictor
  did not catch) — first gets the **re-stack backstop** (`_restackSlice`): the
  slice is re-implemented *on the already-assembled branch* via the shared
  `_runSlice` (behind a `_RestackSliceIo`) and re-gated; a green re-run leaves the
  correctly-based commit on the branch and assembly continues. Only a *failed*
  re-stack is a true integration clash → a draft `[NEEDS HUMAN]` PR. Nothing is
  ever rolled back past the slice's own pre-attempt tip.
- **Dashboard.** When stdout is a tty, a 1s `Timer` re-renders one status line per
  in-flight slice (cursor-up overwrite); workers log to files so it never tears.

### Conventions that matter

- **The harness commits, the agent does not.** The implementer prompt forbids
  committing and no longer self-reviews; `GitOps.commitAll` makes the per-issue
  slice, and the independent `diff-verifier` gate is the only review.
- **Artifact excludes.** `GitOps.artifactExcludes` (`.remember` plus the three
  bundled review agents under `.claude/agents/`, mirroring
  `AgentInstaller.bundledAgents`) is excluded from drift detection and commits so
  tooling churn — and the agents the harness drops in — never ride along.
- **Gates shell out to `fvm flutter`** in the *target* repo, writing logs to
  `/tmp/ralph-analyze.log` and `/tmp/ralph-test.log`. Per-issue the test gate is
  **scoped** to the slice's diff; the **full** suite runs once at the PR gate.
- **Cost ledger (`call_log.dart`).** Every completed `claude` call appends one
  `CallRecord` (phase, issue/prd, model, attempt, cost/turns/duration, ctx
  headroom, outcome, denials) to `.dartralph/calls.jsonl` — a durable,
  git-excluded mirror of `TraceStore`. The data the human transcript prints as
  `└ N turns · $X · Ys` and then forgets is now recoverable for after-the-fact
  analysis ("which phase/model burned the most on this PRD"). `_recordCall` wires
  the six call sites (classify, implement, pr-review×2, review-fix, ci-fix); the
  write is purely additive and never touches the `_prdCostUsd` PR-comment
  accounting, so the ledger and the human-facing number share one `result`
  source. At every run exit `_printCostReport` (`summarizeCalls` →
  `CostReport.render`) prints this run's spend split by phase and by model plus an
  estimated implement lane-tiering saving (the all-Opus counterfactual, grossing
  each cheap-model call up by its `modelCostFactor`). Observability only — it
  never changes loop behavior.
- **Testing split:** pure logic (issue/stream/verdict parsing, the
  `pr_comments.dart` builders) is unit-tested; the `gh`/`git`/`claude` wrappers
  are intentionally untested. Keep new pure logic in those modules and cover it;
  keep the wrappers thin. The parallel drive shares `_runSlice` with the
  sequential path, so the sequential `loop_*` tests now exercise the same slice
  lifecycle both modes run.

## Agent Skills

### Issue tracker
Issues are tracked in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels
Issues use canonical triage labels: `needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`, `wontfix`. See
`docs/agents/triage-labels.md`.

### Domain docs
Single-context layout: `CONTEXT.md` and `docs/adr/` at the repo root (see
`docs/agents/domain.md`). `CONTEXT.md` has a fuller architecture write-up.
