/// Reads one surface-don't-gate channel the reviewer emits as bare
/// `<TAG>: <text>` lines.
///
/// Mirrors the verdict/lane parsers: only a line whose trimmed form starts with
/// the bare `<TAG>:` token counts, so prose merely mentioning the format is
/// ignored. Order is preserved and blank notes are dropped; duplicates are
/// collapsed so a note repeated across lenses surfaces once.
List<String> _taggedNotes(String transcript, String tag) {
  final prefix = '$tag:';
  final seen = <String>{};
  final notes = <String>[];
  for (final line in transcript.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith(prefix)) continue;
    final note = trimmed.substring(prefix.length).trim();
    if (note.isNotEmpty && seen.add(note)) notes.add(note);
  }
  return notes;
}

/// Reads the reviewer's manual-verification notes from a transcript.
///
/// The PR reviewer emits one `MANUAL: <criterion>` line per acceptance
/// criterion whose truth a human must confirm (UI/UX, real-device perf, an
/// external-service behavior, data only visible at runtime) — the autonomous
/// gates cannot settle these from the diff alone. The harness renders them as
/// an unchecked checklist on the draft PR so the human reviewer knows exactly
/// what still needs eyes.
List<String> manualNotes(String transcript) =>
    _taggedNotes(transcript, 'MANUAL');

/// Reads the reviewer's structural / simplification observations.
///
/// The PR reviewer's structural lens emits one `STRUCTURAL: <observation>` line
/// per subjective maintainability opportunity it sees across the *assembled*
/// diff — duplicated logic two slices each reinvented, a branch/mode/wrapper
/// that could collapse, incidental complexity a simpler path would remove. The
/// assembled-diff review is the only reviewer that sees the whole PRD, so it is
/// the only place these can be caught. They are surfaced for the human, never
/// gated on — the objective hard-rule violations that *do* gate ride the
/// verdict, not this channel.
List<String> structuralNotes(String transcript) =>
    _taggedNotes(transcript, 'STRUCTURAL');
