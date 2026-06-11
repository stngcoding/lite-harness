# Reliability & SDLC Hardening Plan

Goal: make the issue→branch→gate→PR orchestration **solid** and **SDLC-native**
by leaning on the git / github / gh / claude ecosystem instead of hand-rolled
mechanisms. Plan only — no code yet.

## Locked decisions

- **Closure = green-gate.** Close a sub-issue as soon as local analyze + tests +
  diff-verifier pass (pre-merge), as today (`loop.dart:234`). Accepted tradeoff:
  an issue can close before its PR merges. → merge-driven closure **dropped**.
- **Docs.** Maintain both `AGENTS.md` (tool-agnostic) and `CLAUDE.md`. Keep in
  sync on every edit.

---

## Tier 1 — Correctness (smallest diff, biggest gain)

### R1. Honor the `claude` exit code
Problem: `stream()` returns the exit code; `_run` discards it
(`claude.dart:32-36`). A rate-limit / crash / `--max-turns` overflow is
indistinguishable from a clean run; a partial errored run still gets committed.

Change: `claude.dart`, `loop.dart`.
```dart
// claude.dart
class ClaudeResult {
  const ClaudeResult(this.transcript, this.exitCode);
  final String transcript;
  final int exitCode;
  bool get ok => exitCode == 0;
}
Future<ClaudeResult> _run(List<String> args) async {
  final r = StreamRenderer();
  final code = await _proc.stream('claude', args, onLine: r.onLine);
  return ClaudeResult(r.transcript, code);
}
```
```dart
// loop.dart _processSub, right after implement()
final run = await claude.implement(model: config.model, prompt: ...);
if (!run.ok) {
  await _failSlice(issue, 'claude exited ${run.exitCode} — no clean run');
  return false;            // do NOT commit a partial run
}
```

### R2. Turn cap + timeouts
Problem: a hung `claude` / `gh` / `git` blocks the loop forever; no `--max-turns`.

Change: `claude.dart` (add `--max-turns`), `proc.dart` (optional timeout kills
the process), `config.dart` (`--max-turns`, `--claude-timeout`).
```dart
// proc.dart stream()
final process = await Process.start(executable, arguments);
final killer = timeout == null ? null
    : Timer(timeout, () => process.kill(ProcessSignal.sigterm));
... // existing stdout/stderr drain
final code = await process.exitCode;
killer?.cancel();
return code;
```

### R3. Distinguish transient failure from "no work"
Problem: `readyIssues` returns `const []` on **any** failure (`github.dart:40`),
so a network blip prints "Done." and exits 0.

Change: new pure `lib/src/retry.dart` (unit-tested — fits the testing split);
`github.dart` throws `GhError` on process failure (vs empty-on-decode);
`loop.dart` wraps list calls in `withRetry` and **aborts loudly** (non-zero
exit) when retries are exhausted.
```dart
// retry.dart (pure, testable)
Future<T> withRetry<T>(Future<T> Function() op,
    {int tries = 3, Duration base = const Duration(seconds: 2)}) async { ... }
```
Tests: `test/retry_test.dart` — succeeds-after-N, exhausts-and-throws, backoff
sequence.

---

## Tier 2 — SDLC linkage & crash recovery

### R4. `ralph-working` claim label (crash recovery + no double-run)
Problem: crash after commit, before close ⇒ issue stays `ready-for-agent` ⇒
re-implemented from scratch; two concurrent runs grab the same issue.

Change: `github.dart` (`addLabel`/`removeLabel`), `loop.dart` claim at slice
start / release on terminal outcome, startup reconciliation.
- Claim: `gh issue edit <n> --add-label ralph-working` before `claude.implement`.
- Release: close removes it; on fail, swap to `ready-for-human`.
- Startup reconcile: any lingering `ralph-working` (previous crash) → inspect its
  PRD branch; if the slice committed, resume/close, else relabel
  `ready-for-agent`.
- Run lock: local `~/.dartralph/<repo>.lock` (pid) to stop two local runs.

### S2. Link the branch to the issue via `gh issue develop`
Problem: harness invents `<parent#>-<slug>`; GitHub doesn't know the branch
belongs to the issue.

Change: `_checkoutPrdBranch` creates the branch with
`gh issue develop <parent> --base <base> --name <branch> --checkout`, so it shows
in the issue's Development sidebar and auto-closes on merge. New
`GhCli.developBranch(int parent, {base, name})`. Keep current slug naming via
`--name`; fall back to plain `git checkout -B` if `gh issue develop` fails.

---

## Tier 3 — Native hierarchy, CI gate, observability

### S1. Native sub-issues (behind `--native-hierarchy`)
Problem: parent/child parsed from `## Parent` markdown (`issue.dart:49-59`) —
brittle, invisible to the GitHub UI.

Change: `github.dart` reads parent/sub-issues via `gh api graphql`
(`addSubIssue` family, parent-progress fields); `issue.dart` markdown parse stays
as **fallback** for un-migrated repos. Gate behind a flag for safe rollout.
Note: GitHub has no stable native **"blocked by"** dependency API → keep
`## Blocked by` markdown for blockers (R5 still applies).

### S4. Gate PR-ready on real CI
Problem: readiness uses only local `fvm flutter` + diff-verifier; GitHub checks
ignored.

Change: in `_openPrIfClean`, after draft PR + before `markPrReady`, require
`gh pr checks <url> --watch` (with timeout) **and** diff-verifier PASS. New
`GhCli.prChecks(url) → bool`.

### S5. Run journal (external statefulness)
Write per-issue events to `.dartralph/runs/<ts>.jsonl` (claim, implement-exit,
gate results, verdict, outcome). Gives crash recovery + audit trail. Pure writer,
unit-testable.

### R5 / R6. Pure selection + first orchestrator tests
Fold in architecture-review candidates: resolve `blockersClosed` once into a
pure `ReadyQueue` (candidate 02, also fixes the N-network-calls flakiness);
extract `decideSliceOutcome(facts) → SliceOutcome` (candidate 01); add interfaces
+ in-memory fakes at gh/git/claude (candidate 04) so `HarnessLoop.run()` is
finally testable.

---

## Suggested order

1. **Tier 1** (R1, R2, R3) — stop trusting silent CLI output.
2. **R5** (pure ReadyQueue) — kills selection flakiness, unlocks tests.
3. **Tier 2** (R4, S2) — crash recovery + issue/branch linkage.
4. **R1/R6 tests** — lock in the new reliability behavior.
5. **Tier 3** (S1, S4, S5) — native + observable.

## Unresolved questions

1. **Run lock** — local pidfile (simple, single-host) vs `ralph-working` label as
   the only distributed claim (handles multi-host but racy)? Recommend pidfile +
   label.
2. **`--max-turns` default** — value? (suggest 40 implement / 15 verify.)
3. **Journal location** — `.dartralph/` inside the target repo (gitignored) vs
   `/tmp`? (suggest target repo for survivability.)
4. **Native sub-issues access** — raw `gh api graphql` (no extra install) vs the
   `gh-sub-issue` extension (cleaner, but a dependency)? Recommend raw `gh api`.
5. **Startup reconciliation policy** — auto-resume a crashed slice vs always
   relabel back to `ready-for-agent` for a clean re-run? (suggest relabel.)
