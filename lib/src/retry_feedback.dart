/// The "previous attempt" block for the implementer's `{{RETRY}}` feedback: the
/// patch the failed attempt produced, so the agent fixes forward instead of
/// re-deriving blind and repeating the mistake. The full [diff] is inlined while
/// small ([maxLines]), else the bounded `--stat` [diffStat]; an empty diff
/// yields an empty block.
String previousAttemptBlock(
  String diff,
  String diffStat, {
  int maxLines = 300,
}) {
  if (diff.trim().isEmpty) return '';
  final lineCount = '\n'.allMatches(diff).length + 1;
  final small = lineCount <= maxLines;
  final body = (small ? diff : diffStat).trim();
  final fence = small ? 'diff' : 'diffstat (full patch too large to inline)';
  return '\n\n### Your previous attempt made these changes — do NOT just repeat them\n'
      'These edits did not pass the gates. The errors above are the source of '
      'truth; correct or build on these changes rather than re-emitting them '
      'unchanged.\n'
      '```$fence\n$body\n```';
}
