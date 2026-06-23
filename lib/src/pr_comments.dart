import 'manual_notes.dart';

/// Pure `… → String` builders for the GitHub comments and PR-body sections the
/// loop posts, lifted out of `HarnessLoop` so the wording is unit-testable.

/// The handoff comment when the secret-scan hard-blocks a commit: what tripped
/// each rule (never the value) and the remediation.
String secretBlockComment(List<String> leaks) {
  final items = leaks.map((l) => '- $l').join('\n');
  return '🔒 **Commit blocked — apparent secret in the diff.**\n\n'
      'The harness will not commit a credential into a PR. Findings:\n\n'
      '$items\n\n'
      'Rotate anything real that leaked, remove it from the slice (use env '
      'vars / secret storage instead of a hardcoded literal), then relabel '
      '`ready-for-agent` to re-run.';
}

/// The reviewer's [manualNotes] as an unchecked checklist for the human, or ''
/// when none — acceptance criteria the gates cannot settle from the diff (UI,
/// real-device perf, external-service behavior). Surfaced, never gated on.
String manualSection(String transcript) {
  final notes = manualNotes(transcript);
  if (notes.isEmpty) return '';
  final items = notes.map((n) => '- [ ] $n').join('\n');
  return '\n\n## Manual verification (needs a human)\n$items';
}

/// The reviewer's [structuralNotes] as a non-gating "Maintainability review"
/// section, or '' when none — the "code judo" simplifications the assembled-diff
/// review is the only place to catch. Plain bullets to weigh, not required fixes
/// (the objective hard-rule violations that *do* gate ride the verdict).
String structuralSection(String transcript) {
  final notes = structuralNotes(transcript);
  if (notes.isEmpty) return '';
  final items = notes.map((n) => '- $n').join('\n');
  return '\n\n## Maintainability review (structural)\n$items';
}

/// The full-suite gate output embedded in the PR description as evidence the
/// reviewer can read without re-running anything. [blocks] is one `(label,
/// logTail)` per gate that ran; '' when empty.
String gateEvidence(List<(String label, String tail)> blocks) {
  if (blocks.isEmpty) return '';
  final rendered = blocks
      .map((b) => '`fvm flutter ${b.$1}`\n\n```\n${b.$2}\n```')
      .join('\n\n');
  return '\n\n<details><summary>Gate evidence (full suite)</summary>\n\n'
      '$rendered\n\n</details>';
}

/// The issue comment when every attempt at a slice failed: the gate verdict, the
/// recovery tag, the failing-log tails, and a too-large advisory when the
/// implementer ran out of context.
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
/// review passed, but [reason] kept the PR a draft. Nothing is rolled back.
String ciHandoffComment(String reason) =>
    '🛠️ **CI watch — PR left as a draft.**\n\n'
    'The local gates (`fvm flutter analyze` + `fvm flutter test`) and the '
    'independent review passed, but $reason. The PR is left a draft for a '
    'human; nothing was rolled back.';

/// The issue comment when a parallel slice's worktree will not merge with a
/// blocker that passed this run — a real integration clash between the two.
String mergeConflictComment(int issue, int blocker) =>
    'Could not start #$issue: its worktree could not be merged with blocker '
    '#$blocker (a real integration conflict between the two slices). '
    'Resolve the overlap manually, then relabel `ready-for-agent` to re-run.';

/// The issue/PR comment when a PRD's passed slices cannot be assembled: they
/// passed individually but overlap on integration, and the re-stack backstop
/// ([HarnessLoop._restackSlice]) could not land the slice either.
String integrationConflictComment(int prd, int conflictSlice) =>
    'PRD #$prd could not be assembled automatically: slice #$conflictSlice '
    'conflicts when cherry-picked onto the PRD branch and could not be '
    're-stacked on the assembled slices either. They passed individually but '
    'overlap on integration — resolve the conflict by hand (the per-issue '
    'worktrees under `.dartralph/worktrees/` are kept).';

/// The issue comment when a slice was re-stacked at assembly: its original commit
/// would not cherry-pick (it forked off a base missing a sibling's edit), so the
/// harness re-implemented it on the assembled branch and re-gated green.
String restackCloseComment(int prd, int issue) =>
    "Re-stacked onto PRD #$prd's assembled branch: #$issue's original commit "
    'would not cherry-pick (it forked off a base missing an overlapping '
    "sibling's edit), so the harness re-implemented it on top of the assembled "
    'slices and re-ran analyze + scoped tests green before closing.';

/// The issue comment when a passed slice is closed during a checkpoint: the pool
/// stopped early (a usage limit), so its complete work is landed on the PRD
/// branch now and the PR opens once a re-run drains the remaining slices.
String checkpointCloseComment(int prd) =>
    "Verified by the AFK loop and checkpointed onto PRD #$prd's branch when the "
    'run stopped early (usage limit). Its commit is pushed; the PR for PRD '
    '#$prd opens once the remaining slices finish on a re-run.';

/// Why the PR gate did not open a PR for PRD [prd], in terms a human can act on.
/// Two causes: **nothing to ship** ([openSubs] empty, only [ahead] commits on
/// [branch] — every sub likely failed its gate or already merged) and **PRD not
/// complete** ([openSubs] still open — a `ready-for-agent` sub retries next run,
/// a `ready-for-human` one needs a person). `needsHuman` is true only when a
/// person must act, so the loop comments only then (no spam on a looping harness).
({String text, bool needsHuman}) prSkipExplanation({
  required int prd,
  required int ahead,
  required String base,
  required String branch,
  required List<({int number, bool needsHuman})> openSubs,
}) {
  if (openSubs.isEmpty) {
    return (
      needsHuman: true,
      text:
          'PRD #$prd — no PR opened: nothing to ship '
          '($ahead commits ahead of `$base` on `$branch`).\n'
          'Every sub-issue likely failed its gate — recover a failed attempt '
          'with `git checkout ralph-fail/<n>` and read the sub-issue comments — '
          'or the work already merged.\n'
          'Fix and relabel `ready-for-agent` to retry, or close PRD #$prd if it '
          'is already done.',
    );
  }

  final human = [
    for (final s in openSubs)
      if (s.needsHuman) s.number,
  ];
  final retry = [
    for (final s in openSubs)
      if (!s.needsHuman) s.number,
  ];
  final lines = <String>[
    'PRD #$prd — no PR opened: ${openSubs.length} sub-issue(s) still open, so '
        'the PRD is not complete (the PR opens only once every sub is closed).',
  ];
  if (retry.isNotEmpty) {
    lines.add(
      '• ${_issueRefs(retry)} still `ready-for-agent` — retried automatically '
      'on the next run.',
    );
  }
  if (human.isNotEmpty) {
    lines.add(
      '• ${_issueRefs(human)} `ready-for-human` — needs you; read each issue\'s '
      'own handoff comment, fix it, and close it (or relabel `ready-for-agent` '
      'to let the harness retry).',
    );
  }
  lines.add('Branch `$branch` holds $ahead commit(s), waiting.');
  return (text: lines.join('\n'), needsHuman: human.isNotEmpty);
}

String _issueRefs(List<int> numbers) => numbers.map((n) => '#$n').join(', ');
