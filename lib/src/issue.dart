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

int parentOf(String body, int ownNumber) {
  final section = _section(body, 'Parent');
  final match = RegExp(r'#(\d+)|/issues/(\d+)').firstMatch(section);
  final number = match?.group(1) ?? match?.group(2);
  return number == null ? ownNumber : int.parse(number);
}

List<int> blockersOf(String body) => RegExp(r'#(\d+)')
    .allMatches(_section(body, 'Blocked by'))
    .map((m) => int.parse(m.group(1)!))
    .toList();

/// Numbers of issues in [issues] that are the `## Parent` of at least one
/// other issue — the umbrella PRDs. An umbrella only groups its slices and is
/// closed by the PR (`Closes #parent`); implementing it as a work item redoes
/// the whole PRD scope once more on top of every slice.
Set<int> umbrellaNumbers(Iterable<Issue> issues) {
  final umbrellas = <int>{};
  for (final issue in issues) {
    final parent = parentOf(issue.body, issue.number);
    if (parent != issue.number) umbrellas.add(parent);
  }
  return umbrellas;
}

String _section(String body, String heading) {
  final lines = body.split('\n');
  final buffer = StringBuffer();
  var inSection = false;
  for (final line in lines) {
    if (RegExp('^## *$heading').hasMatch(line)) {
      inSection = true;
      continue;
    }
    if (line.startsWith('## ')) {
      inSection = false;
      continue;
    }
    if (inSection) buffer.writeln(line);
  }
  return buffer.toString();
}

String slugify(String input) {
  final slug = input
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  final cut = slug.length > 50 ? slug.substring(0, 50) : slug;
  return cut.replaceAll(RegExp('-+\$'), '');
}
