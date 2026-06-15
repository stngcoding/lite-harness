# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`dartralph` is a Dart CLI that automates draining a PRD's `ready-for-agent`
GitHub sub-issues: it runs the `claude` CLI per issue, gates each slice
(analyze + tests + an independent reviewer), then opens one PR per PRD. It is a
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
`--model <model>` (MODEL, default `sonnet`), `--issue N`, `--once`, `--dry-run`.

## Architecture

The entrypoint `bin/dartralph.dart` parses args, builds a `Config`, wires the
collaborators, and hands off to `HarnessLoop.run()` in `lib/src/loop.dart`. The
public surface is re-exported from `lib/dartralph.dart`.

`HarnessLoop` is the orchestrator and holds all the policy; everything else is a
thin, side-effecting wrapper around an external CLI:

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
   test`). The test gate runs only the tests the slice's diff touches —
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
   pipeline — triage → five independent review lenses (CLAUDE.md, bug scan, git
   history, prior PRs, in-code comments) fanned out via `Task` → per-issue 0–100
   confidence scoring → drop everything below 80 → a cited PASS/FAIL. It still
   ends in the single bare `VERDICT:` line the harness reads.
5. **Stranded-PRD sweep.** After the ready queue empties, `_shipStrandedPrds`
   walks local `<parent#>-<slug>` branches and PRs any whose parent is still
   OPEN, has no open managed subs, commits ahead, and no existing open PR. This
   catches PRDs whose last failed sub was resolved (re-run or human close) after
   the PRD had already fallen out of selection — without it, that branch never
   gets a PR. Idempotent, so a looping harness never re-opens or spams.

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
- **Testing split:** pure logic (issue/stream/verdict parsing) is unit-tested;
  the `gh`/`git`/`claude` wrappers are intentionally untested. Keep new pure
  logic in those modules and cover it; keep the wrappers thin.

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
