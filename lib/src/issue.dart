class Issue {
  const Issue({
    required this.number,
    required this.title,
    required this.body,
    required this.labels,
    required this.url,
  });

  factory Issue.fromJson(Map<String, dynamic> json) => Issue(
    number: json['number'] as int,
    title: json['title'] as String,
    body: json['body'] as String? ?? '',
    labels: [
      for (final label in json['labels'] as List? ?? [])
        (label as Map)['name'] as String,
    ],
    url: json['url'] as String,
  );

  final int number;
  final String title;
  final String body;
  final List<String> labels;
  final String url;
}

int priorityScore(List<String> labels) {
  final lowered = labels.map((l) => l.toLowerCase()).toList();
  bool any(String pattern) => lowered.any((l) => RegExp(pattern).hasMatch(l));
  if (any('critical|p0|urgent|blocker')) return 0;
  if (any('high|p1|important')) return 1;
  if (any('bug|defect|fix')) return 2;
  if (any('medium|p2')) return 3;
  if (any('enhancement|feature')) return 4;
  if (any('low|p3|minor')) return 5;
  return 6;
}

List<Issue> sortReady(List<Issue> issues) {
  final sorted = [...issues];
  sorted.sort((a, b) {
    final byScore = priorityScore(a.labels).compareTo(priorityScore(b.labels));
    return byScore != 0 ? byScore : a.number.compareTo(b.number);
  });
  return sorted;
}

String? phaseOf(String body) {
  final text = _section(body, 'Phase').trim();
  return text.isEmpty ? null : text;
}

int parentOf(String body, int ownNumber) =>
    _firstRef(_section(body, 'Parent')) ?? ownNumber;

List<int> blockersOf(String body) {
  final section = _section(body, 'Blocked by');
  // A "None" section means no blockers. Stop here before the `#N` scan so prose
  // after it ("None — start on PR #338") isn't read as a phantom blocker; the
  // leading-markup tolerance also catches the inline `**Blocked by:** None …`.
  if (RegExp(r'^[\s*_>-]*none\b', caseSensitive: false).hasMatch(section)) {
    return [];
  }
  return RegExp(r'#(\d+)|/issues/(\d+)')
      .allMatches(section)
      .map((m) => int.parse(m.group(1) ?? m.group(2)!))
      .toList();
}

int? _firstRef(String text) {
  final match = RegExp(r'#(\d+)|/issues/(\d+)').firstMatch(text);
  final number = match?.group(1) ?? match?.group(2);
  return number == null ? null : int.parse(number);
}

/// Issue numbers that are the `## Parent` of at least one other issue — the
/// umbrella PRDs. An umbrella only groups its slices (the PR closes it via
/// `Closes #parent`); implementing it would redo the whole PRD scope per slice.
Set<int> umbrellaNumbers(Iterable<Issue> issues) {
  final umbrellas = <int>{};
  for (final issue in issues) {
    final parent = parentOf(issue.body, issue.number);
    if (parent != issue.number) umbrellas.add(parent);
  }
  return umbrellas;
}

/// The ready slices eligible to start right now: not [excluded] (handled or in
/// flight), not an umbrella, and every `## Blocked by` issue and every [implicit]
/// file-overlap blocker [satisfied] (closed before this run or passed in it).
/// Ordered by [sortReady]. Pure (no GitHub state) so the scheduler's hardest
/// correctness concern is unit-testable.
List<Issue> eligibleSlices(
  List<Issue> ready, {
  required Set<int> satisfied,
  required Set<int> excluded,
  Map<int, Set<int>> implicit = const {},
}) {
  final umbrellas = umbrellaNumbers(ready);
  return sortReady([
    for (final issue in ready)
      if (!excluded.contains(issue.number) &&
          !umbrellas.contains(issue.number) &&
          blockersOf(issue.body).every(satisfied.contains) &&
          (implicit[issue.number] ?? const <int>{}).every(satisfied.contains))
        issue,
  ]);
}

/// The text under a `## $heading` block, or — when there is none — the remainder
/// of an inline labeled line (`**Parent:** #366`, `- _Blocked by_: #264`). Both
/// forms appear in human-written templates and must resolve to the same edges,
/// or a PRD's slices silently detach from their umbrella.
String _section(String body, String heading) {
  final headingLine = RegExp('^## *$heading');
  final lines = body.split('\n');
  final buffer = StringBuffer();
  var inSection = false;
  for (final line in lines) {
    if (headingLine.hasMatch(line)) {
      inSection = true;
      continue;
    }
    if (line.startsWith('## ')) {
      inSection = false;
      continue;
    }
    if (inSection) buffer.writeln(line);
  }
  if (buffer.isNotEmpty) return buffer.toString();
  final inline = RegExp(
    '^[ \\t>*_-]*$heading[ \\t]*[*_]*[ \\t]*:(.*)\$',
    caseSensitive: false,
    multiLine: true,
  ).firstMatch(body);
  return inline?.group(1) ?? '';
}

String slugify(String input) {
  final slug = input
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  final cut = slug.length > 50 ? slug.substring(0, 50) : slug;
  return cut.replaceAll(RegExp('-+\$'), '');
}
