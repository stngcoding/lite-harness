/// Reads the reviewer's verdict: only an exact `VERDICT: PASS`/`VERDICT: FAIL`
/// line counts, last one wins, so prose mentioning the format can't flip it.
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

/// The PR comment from a diff-verifier run: the block under the last
/// `### Code review` heading, dropping the orchestrator's earlier narration.
/// Falls back to the whole transcript if no heading is found (an errored run).
String reviewComment(String transcript) {
  final i = transcript.lastIndexOf('### Code review');
  return i == -1 ? transcript.trim() : transcript.substring(i).trim();
}

/// How risky a slice is, set by intake to scale the implementer guidance and
/// reviewer bar (never blocks the loop). Ordered least → most risky so a PRD
/// can take the max of its slices' lanes.
enum RiskLane {
  tiny('tiny'),
  normal('normal'),
  highRisk('high-risk');

  const RiskLane(this.label);

  /// The protocol token the intake agent emits and the parser reads.
  final String label;
}

/// Reads the intake risk lane, mirroring [hasPassVerdict]: only an exact
/// `LANE: <label>` line counts, last one wins. Null when absent — the caller
/// defaults to a safe lane rather than treating absence as a failure.
RiskLane? parseLane(String transcript) {
  RiskLane? last;
  for (final line in transcript.split('\n')) {
    final trimmed = line.trim();
    for (final lane in RiskLane.values) {
      if (trimmed == 'LANE: ${lane.label}') last = lane;
    }
  }
  return last;
}
