# AGENTS.md

This file provides guidance to any AI coding agent (Claude Code, Pi, Codex,
Cursor, …) working with code in this repository. It is kept in sync with
`CLAUDE.md`; edit both, or treat this as the source and `CLAUDE.md` as a copy.

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
- `AgentInstaller` (`agents.dart`) — ships the `diff-verifier` agent the
  `verify` gate depends on. On startup (non-dry-run) it writes the bundled
  `lib/agents/diff-verifier.md` into the target repo's
  `.claude/agents/diff-verifier.md` *only if absent*, so a fresh clone is never
  silently failed by every gate; a target that ships its own tuned reviewer
  keeps it.
- `ProcessRunner` (`proc.dart`) — the only place that actually spawns processes
  (`run` for buffered, `stream` for line-by-line). All wrappers depend on it,
  which is what makes the loop testable in principle.

Pure, dependency-free logic is isolated into the modules that carry the unit
tests — this is the code to touch carefully:

- `issue.dart` — `Issue` model + parsing of `## Parent` / `## Blocked by`
  sections, `priorityScore` (label → rank), `sortReady`, `slugify`.
- `claude_stream.dart` — parses `stream-json` lines into `StreamEvent`s and
  renders a live transcript; `StreamRenderer.transcript` is the string the
  verdict is read from.
- `verdict.dart` — `hasPassVerdict`: a transcript passes only if the **last**
  line that is exactly `VERDICT: PASS` (not `FAIL`, not prose mentioning it)
  says PASS. This protocol is load-bearing; the reviewer agent must emit a bare
  verdict line.

### The per-PRD flow (loop.dart)

1. Select the active PRD from the highest-priority *processable* ready issue
   (processable = every `## Blocked by` issue is CLOSED). A parent-less issue is
   its own PRD-of-one.
2. Check out `<parent#>-<slug>` off `origin/<base>` (resume if it exists; park
   uncommitted drift in a stash first).
3. For each processable sub-issue: **Implement** (`claude -p`) → **commit**
   immediately → **gate** (`fvm flutter analyze` + `fvm flutter test` + an
   independent `diff-verifier` over `baseline..HEAD`). PASS → close the issue;
   FAIL → tag `ralph-fail/<n>`, `reset --hard` to baseline, relabel
   `ready-for-human`, comment with reviewer output + log tails.
4. On a clean sweep with real commits ahead of base: push, open one draft PR,
   run a PR-level `diff-verifier` over the whole diff, mark ready only if it
   passes.

### Conventions that matter

- **The harness commits, the agent does not.** The implementer prompt forbids
  committing and no longer self-reviews; `GitOps.commitAll` makes the per-issue
  slice, and the independent `diff-verifier` gate is the only review.
- **Artifact excludes.** `GitOps.artifactExcludes` (`.remember`,
  `.claude/agents/diff-verifier.md`) is excluded from drift detection and
  commits so tooling churn — and the bundled agent the harness drops in — never
  rides along.
- **Gates shell out to `fvm flutter`** in the *target* repo, writing logs to
  `/tmp/ralph-analyze.log` and `/tmp/ralph-test.log`.
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
