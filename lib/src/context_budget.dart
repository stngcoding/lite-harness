// Just-in-time context budgeting: inject the high-signal head/tail of a long
// input plus a pointer to fetch the rest on demand, rather than flooding the
// prompt. The slice's own issue body is never clamped — only the surrounding
// PRD context and comment thread, which the agent can pull in full when needed.

/// The first [maxLines] lines of a PRD [body], with a pointer to read the full
/// issue when it was truncated. A body already within budget passes through
/// unchanged.
String clampPrdBody(String body, int parent, {int maxLines = 30}) {
  final lines = body.split('\n');
  if (lines.length <= maxLines) return body;
  final head = lines.take(maxLines).join('\n');
  final dropped = lines.length - maxLines;
  return '$head\n\n_($dropped more line(s) — `gh issue view $parent` for the '
      'full PRD.)_';
}

/// The last [keep] comment [blocks] joined (the newest carry the freshest
/// refinements), with a pointer to the rest when older ones were dropped.
/// Fewer than [keep] pass through unchanged.
String clampComments(List<String> blocks, int issue, {int keep = 5}) {
  if (blocks.length <= keep) return blocks.join('\n');
  final dropped = blocks.length - keep;
  final tail = blocks.sublist(blocks.length - keep).join('\n');
  return '_($dropped older comment(s) omitted — `gh issue view $issue '
      '--comments` for all.)_\n\n$tail';
}
