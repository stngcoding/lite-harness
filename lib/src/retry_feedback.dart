/// The "previous attempt" block appended to the implementer's `{{RETRY}}`
/// feedback: the patch the failed attempt actually produced, so the agent fixes
/// forward from what it already tried instead of re-deriving the slice blind and
/// repeating the same mistake.
///
/// The full [diff] is inlined only while it is small enough to read
/// ([maxLines]); past that the bounded `--stat` [diffStat] is used instead so a
/// large slice's patch never floods the prompt. An empty diff yields an empty
/// block (the no-changes retry path has nothing to show).
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
