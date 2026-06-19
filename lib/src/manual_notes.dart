/// Reads the reviewer's manual-verification notes from a transcript.
///
/// The PR reviewer emits one `MANUAL: <criterion>` line per acceptance
/// criterion whose truth a human must confirm (UI/UX, real-device perf, an
/// external-service behavior, data only visible at runtime) — the autonomous
/// gates cannot settle these from the diff alone. The harness renders them as
/// an unchecked checklist on the draft PR so the human reviewer knows exactly
/// what still needs eyes.
///
/// Mirrors the verdict/lane parsers: only a line whose trimmed form starts with
/// the bare `MANUAL:` token counts, so prose merely mentioning the format is
/// ignored. Order is preserved and blank notes are dropped; duplicates are
/// collapsed so a criterion repeated across lenses surfaces once.
List<String> manualNotes(String transcript) {
  final seen = <String>{};
  final notes = <String>[];
  for (final line in transcript.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('MANUAL:')) continue;
    final note = trimmed.substring('MANUAL:'.length).trim();
    if (note.isNotEmpty && seen.add(note)) notes.add(note);
  }
  return notes;
}
