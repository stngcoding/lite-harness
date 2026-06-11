# CONTEXT: dartralph

## Purpose

dartralph is a minimal AFK (away-from-keyboard) harness that automates implementing GitHub issues using the Claude CLI. It processes "ready-for-agent" sub-issues grouped by PRDs (Product Requirements Documents), running implementations through gated reviews, then opens one PR per PRD with a final review gate. It's a Dart port of the legacy bash harness, designed for single-purpose orchestration of issue → branch → PR workflows.

## Entities

### PRD (Product Requirement Document)
A parent GitHub issue representing a feature or epic. Contains one or more sub-issues. Each PRD gets its own branch (`<parent#>-<slug>`) and PR. A parent-less issue is treated as its own PRD-of-one.

### Issue
A GitHub issue with:
- **number** — GitHub issue number
- **title** — display name
- **body** — parsed for sections like `## Parent`, `## Blocked by`
- **labels** — used for priority scoring and state (e.g., `ready-for-agent`, `critical`, `p1`)
- **url** — GitHub web link

### Sub-issue
An issue grouped under a PRD (via its `## Parent` section). Only "ready-for-agent" sub-issues are processed. An issue is *processable* when all issues in its `## Blocked by` section are closed.

### Branch
Per-PRD branch (`<parent#>-<slug>`) checked out from `origin/<base>`. Accumulates commits from all sub-issues in the PRD. Uncommitted drift is stashed before checkout.

### Verdict
The outcome of a Claude review run over a diff. Parsed from the review output to determine if a sub-issue or PR is approved (PASS) or requires rework (FAIL).

## Architecture

### Layers

1. **Config** (`config.dart`)
   - CLI option parsing: `--repo`, `--state`, `--base`, `--model`, `--issue`, `--once`, `--dry-run`
   - Defaults from env vars: `REPO`, `STATE`, `BASE`, `MODEL`

2. **GitHub Integration** (`github.dart`)
   - Fetch issues by state (open, closed, all) and labels
   - Update issue labels and state
   - Post comments with review output and logs

3. **Git Integration** (`git.dart`)
   - Checkout branches (resume or create new)
   - Stash uncommitted changes
   - Commit with precise, per-issue messages
   - Push to origin

4. **Claude Integration** (`claude.dart`, `claude_stream.dart`, `agents.dart`)
   - Run `claude -p` for implementations (with issue body + comments)
   - Run `claude --agent diff-verifier` for reviews — `--agent` keeps the
     reviewer's context window clean (its own system prompt, not the target
     repo's `CLAUDE.md`/skills)
   - `AgentInstaller` ships the bundled `diff-verifier` into the target repo's
     `.claude/agents/` when absent, so the gate always has its reviewer
   - Stream output parsing for real-time feedback

5. **Issue Logic** (`issue.dart`)
   - Parse `## Parent` and `## Blocked by` sections from issue body
   - Priority scoring based on labels (critical → p0 → p1 → bug → p2 → enhancement → p3 → default)
   - Sort issues by priority and number

6. **Review** (`verdict.dart`)
   - Parse Claude review output to detect PASS/FAIL verdicts
   - Determine if a diff is approved

7. **Main Loop** (`loop.dart`)
   - Orchestrates the per-PRD workflow:
     1. Find highest-priority processable sub-issue
     2. Checkout branch
     3. For each sub-issue: Implement → Commit → Gate (analyze + tests + diff-verifier)
     4. On clean sweep: Push → Open PR → PR-level review gate
   - On gate failure: tag attempt, rollback, relabel `ready-for-human`

### Data Flow

```
GitHub Issues
  ↓ (fetch by state + label)
Issue[] (parse parent/blocking)
  ↓ (sort by priority)
Processable Issue
  ↓ (checkout branch)
Git Branch
  ↓ (for each sub-issue)
  ├─ Claude Implement → Commit
  ├─ Gate: analyze + tests + Diff-verifier (independent, authoritative)
  ├─ PASS: Close issue
  └─ FAIL: Tag attempt, rollback, relabel
  ↓
Push → Open PR
  ↓
PR-level Diff-verifier Review
  ↓
Mark Ready (PASS) or Request Changes (FAIL)
```

## Testing & Quality

### Unit Tests
Pure logic is unit-tested:
- Issue parsing (parent, blocking, priority)
- Priority scoring
- Verdict detection
- Stream-JSON parsing

See `test/` directory.

### Untested (by design)
- `gh` / `git` / `claude` CLI orchestration is thin wrappers
- Integration tests not required; the harness is simple enough that logic tests provide confidence

### Gates

1. **Mechanical gates** — `fvm flutter analyze` + `fvm flutter test` run over the committed slice
2. **Independent review (Authoritative)** — explicit `claude --agent diff-verifier` run over `baseline..HEAD`, with its own clean context window. The implementer does NOT self-review; this is the only review.
3. **PR-level review** — `diff-verifier` runs over the full PR diff before marking ready

## Constraints & Conventions

- **Sequential processing** — one sub-issue at a time; no parallelism
- **Precise commits** — one commit per sub-issue, immediately after implementation
- **Drift handling** — uncommitted changes are stashed before checkout
- **Deterministic retries** — failed issues tagged (`ralph-fail/<n>`), rolled back, relabeled for human review
- **Single PR per PRD** — all sub-issues in a PRD are collected into one branch/PR
- **Base branch configurable** — default `dev`; set via `--base` or `BASE` env var
- **Model configurable** — default `sonnet`; set via `--model` or `MODEL` env var
- **Dry-run mode** — prints PRD/sub-issue order without making changes
- **Issue number filter** — `--issue N` processes only issue N, then exits
- **One-shot mode** — `--once` processes exactly one sub-issue, then exits
