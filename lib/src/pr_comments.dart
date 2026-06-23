import 'manual_notes.dart';

/// Pure builders for the GitHub comments and PR-body sections the loop posts.
///
/// These were lifted out of `HarnessLoop` so the wording is unit-testable and
/// the orchestrator keeps only the thin side-effecting glue (read the log file,
/// then call `gh.commentOn…`). Every function here is a pure `… → String`: the
/// loop reads the filesystem and passes the already-tailed log text in.

/// The handoff comment body when the secret-scan hard-blocks a commit: lists
/// what tripped each rule (never the value) and the remediation. The slice is
/// not committed, so there is no log tail to attach.
String secretBlockComment(List<String> leaks) {
  final items = leaks.map((l) => '- $l').join('\n');
  return '🔒 **Commit blocked — apparent secret in the diff.**\n\n'
      'The harness will not commit a credential into a PR. Findings:\n\n'
      '$items\n\n'
      'Rotate anything real that leaked, remove it from the slice (use env '
      'vars / secret storage instead of a hardcoded literal), then relabel '
      '`ready-for-agent` to re-run.';
}

/// Renders the reviewer's manual-verification notes ([manualNotes]) as an
/// unchecked checklist for the human reviewing the draft PR, or '' when there
/// are none. These are acceptance criteria the autonomous gates cannot settle
/// from the diff (UI, real-device perf, external-service behavior) — surfaced,
/// never gated on.
String manualSection(String transcript) {
  final notes = manualNotes(transcript);
  if (notes.isEmpty) return '';
  final items = notes.map((n) => '- [ ] $n').join('\n');
  return '\n\n## Manual verification (needs a human)\n$items';
}

/// Renders the reviewer's structural / simplification observations
/// ([structuralNotes]) as a non-gating "Maintainability review" section for the
/// human reviewing the draft PR, or '' when there are none. These are the
/// "code judo" findings the assembled-diff review is the only place to catch —
/// logic two slices each reinvented, a branch or wrapper that could collapse,
/// incidental complexity a simpler path removes. Plain bullets, not a
/// checklist: they are observations to weigh, not required fixes (the objective
/// hard-rule violations that *do* gate ride the verdict, never this list).
String structuralSection(String transcript) {
  final notes = structuralNotes(transcript);
  if (notes.isEmpty) return '';
  final items = notes.map((n) => '- $n').join('\n');
  return '\n\n## Maintainability review (structural)\n$items';
}

/// The full-suite gate output embedded in the PR description as evidence the
/// human reviewer can read without re-running anything. [blocks] is one
/// `(label, logTail)` per gate that ran (`analyze`, `test`); '' when empty
/// (e.g. a draft opened for a merge conflict before the suite ran).
String gateEvidence(List<(String label, String tail)> blocks) {
  if (blocks.isEmpty) return '';
  final rendered = blocks
      .map((b) => '`fvm flutter ${b.$1}`\n\n```\n${b.$2}\n```')
      .join('\n\n');
  return '\n\n<details><summary>Gate evidence (full suite)</summary>\n\n'
      '$rendered\n\n</details>';
}

/// The issue comment when every attempt at a slice failed: the gate verdict,
/// the recovery tag, the failing-log tails ([logs], already read by the loop),
/// and a too-large advisory when the implementer ran out of context.
String failComment(
  int number, {
  required bool analyzeOk,
  required bool testOk,
  required String logs,
  String implementSummary = '',
  bool contextStarved = false,
}) {
  final starvedNote = contextStarved
      ? '\n\n⚠️ The implementer ran low on context (<15% free) before '
            'failing — this slice is likely too large. Consider splitting it '
            'into smaller sub-issues.'
      : '';
  return 'AFK verify FAILED '
      '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}).'
      '$implementSummary\n\n'
      'Failed attempt preserved at tag `ralph-fail/$number` '
      '(recover with `git checkout ralph-fail/$number`).\n\n'
      '**Logs**\n```\n$logs\n```$starvedNote';
}

/// The PR comment when CI watching ends without a green: the local gates and
/// review passed, but [reason] kept the PR from going ready, so it is left a
/// draft for a human. Nothing is rolled back.
String ciHandoffComment(String reason) =>
    '🛠️ **CI watch — PR left as a draft.**\n\n'
    'The local gates (`fvm flutter analyze` + `fvm flutter test`) and the '
    'independent review passed, but $reason. The PR is left a draft for a '
    'human; nothing was rolled back.';

/// The issue comment when a parallel slice cannot start because its worktree
/// will not merge with a blocker that passed earlier this run — a real
/// integration clash between the two slices.
String mergeConflictComment(int issue, int blocker) =>
    'Could not start #$issue: its worktree could not be merged with blocker '
    '#$blocker (a real integration conflict between the two slices). '
    'Resolve the overlap manually, then relabel `ready-for-agent` to re-run.';

/// The issue/PR comment when a PRD's passed slices cannot be cherry-picked onto
/// its branch — they passed individually but overlap on integration.
String integrationConflictComment(int prd, int conflictSlice) =>
    'PRD #$prd could not be assembled automatically: slice #$conflictSlice '
    'conflicts when cherry-picked onto the PRD branch. The slices passed '
    'individually but overlap on integration — resolve the conflict by hand '
    '(the per-issue worktrees under `.dartralph/worktrees/` are kept).';
