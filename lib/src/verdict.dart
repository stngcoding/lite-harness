/// Reads the reviewer's verdict from a transcript.
///
/// Only a line that is exactly `VERDICT: PASS` or `VERDICT: FAIL` counts,
/// and the last such line wins — prose that merely mentions the format
/// (e.g. the reviewer restating its instructions) cannot flip the outcome.
bool hasPassVerdict(String transcript) {
  String? lastVerdict;
  for (final line in transcript.split('\n')) {
    final trimmed = line.trim();
    if (trimmed == 'VERDICT: PASS' || trimmed == 'VERDICT: FAIL') {
      lastVerdict = trimmed;
    }
  }
  return lastVerdict == 'VERDICT: PASS';
}

/// The PR comment to post from a diff-verifier PR-mode run.
///
/// Mode B always prints its comment under a `### Code review` heading, so the
/// posted comment is just that block — sliced from the last such heading. The
/// orchestrator's intermediate narration (triage, panel fan-out, the line where
/// it skips the repo's skill-evaluation preamble) sits *before* the heading and
/// is dropped. If no heading is found (an errored run), the trimmed transcript
/// is returned so something still surfaces.
String reviewComment(String transcript) {
  final i = transcript.lastIndexOf('### Code review');
  return i == -1 ? transcript.trim() : transcript.substring(i).trim();
}
