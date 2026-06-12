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
