/// Reads one surface-don't-gate channel the reviewer emits as bare
/// `<TAG>: <text>` lines. Order preserved, blanks dropped, duplicates collapsed
/// so a note repeated across lenses surfaces once.
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

/// The reviewer's `MANUAL: <criterion>` lines — acceptance criteria a human
/// must confirm (UI/UX, real-device perf, external-service behavior) that the
/// gates cannot settle from the diff. Rendered as an unchecked PR checklist.
List<String> manualNotes(String transcript) =>
    _taggedNotes(transcript, 'MANUAL');

/// The structural lens's `STRUCTURAL: <observation>` lines — subjective
/// maintainability opportunities across the *assembled* diff (duplication two
/// slices reinvented, a collapsible branch/wrapper). Surfaced for the human,
/// never gated; the objective hard-rule violations ride the verdict instead.
List<String> structuralNotes(String transcript) =>
    _taggedNotes(transcript, 'STRUCTURAL');
