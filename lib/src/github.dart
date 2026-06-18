import 'dart:convert';

import 'issue.dart';
import 'proc.dart';

class GhCli {
  GhCli(this._proc, this.repo);

  final ProcessRunner _proc;
  final String repo;

  static Future<String?> detectRepo(ProcessRunner proc) async {
    final result = await proc.run('gh', [
      'repo',
      'view',
      '--json',
      'nameWithOwner',
      '-q',
      '.nameWithOwner',
    ]);
    final name = result.stdout.trim();
    return result.ok && name.isNotEmpty ? name : null;
  }

  Future<List<Issue>> readyIssues(String state) async =>
      sortReady(await issuesWithLabel('ready-for-agent', state));

  Future<List<Issue>> issuesWithLabel(String label, String state) async {
    final result = await _proc.run('gh', [
      'issue',
      'list',
      '--repo',
      repo,
      '--state',
      state,
      '--label',
      label,
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,url',
    ]);
    if (!result.ok) return const [];
    try {
      final list = jsonDecode(result.stdout) as List;
      return [
        for (final json in list) Issue.fromJson(json as Map<String, dynamic>),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// Metadata for [ref] (a PR number or URL), or null when no such PR exists.
  /// [base]/[head] are the branch names; [url] is the canonical PR ref the rest
  /// of the harness comments on and marks ready.
  Future<({int number, String title, String head, String base, String url})?>
  prInfo(String ref) async {
    final result = await _proc.run('gh', [
      'pr',
      'view',
      ref,
      '--repo',
      repo,
      '--json',
      'number,title,headRefName,baseRefName,url',
    ]);
    if (!result.ok) return null;
    try {
      final json = jsonDecode(result.stdout) as Map<String, dynamic>;
      return (
        number: json['number'] as int,
        title: json['title'] as String,
        head: json['headRefName'] as String,
        base: json['baseRefName'] as String,
        url: json['url'] as String,
      );
    } on FormatException {
      return null;
    }
  }

  /// Checks out [ref]'s head branch locally (handles forks and remote-only
  /// branches via `gh pr checkout`). Returns false when the checkout failed.
  Future<bool> checkoutPr(String ref) async {
    final result = await _proc.run('gh', [
      'pr',
      'checkout',
      ref,
      '--repo',
      repo,
    ]);
    return result.ok;
  }

  /// URL of the open PR whose head is [branch], or null when none exists.
  Future<String?> openPrForBranch(String branch) async {
    final result = await _proc.run('gh', [
      'pr',
      'list',
      '--repo',
      repo,
      '--head',
      branch,
      '--state',
      'open',
      '--json',
      'url',
      '-q',
      '.[0].url',
    ]);
    final url = result.stdout.trim();
    return result.ok && url.isNotEmpty ? url : null;
  }

  Future<String> issueState(int number) async {
    final result = await _proc.run('gh', [
      'issue',
      'view',
      '$number',
      '--repo',
      repo,
      '--json',
      'state',
      '-q',
      '.state',
    ]);
    final state = result.stdout.trim();
    return result.ok && state.isNotEmpty ? state : 'OPEN';
  }

  Future<bool> allBlockersClosed(String body) async {
    for (final blocker in blockersOf(body)) {
      if (await issueState(blocker) != 'CLOSED') return false;
    }
    return true;
  }

  Future<String> issueComments(int number) async {
    final result = await _proc.run('gh', [
      'issue',
      'view',
      '$number',
      '--repo',
      repo,
      '--json',
      'comments',
    ]);
    if (!result.ok) return '';
    try {
      final decoded = jsonDecode(result.stdout) as Map<String, dynamic>;
      final comments = decoded['comments'] as List? ?? const [];
      return [
        for (final comment in comments.cast<Map<String, dynamic>>())
          '**${(comment['author'] as Map?)?['login']}** '
              '(${comment['createdAt']}):\n${comment['body']}\n',
      ].join('\n');
    } on FormatException {
      return '';
    }
  }

  Future<String> issueTitle(int number) async {
    final result = await _proc.run('gh', [
      'issue',
      'view',
      '$number',
      '--repo',
      repo,
      '--json',
      'title',
      '-q',
      '.title',
    ]);
    final title = result.stdout.trim();
    return result.ok && title.isNotEmpty ? title : 'prd-$number';
  }

  Future<String> issueBody(int number) async {
    final result = await _proc.run('gh', [
      'issue',
      'view',
      '$number',
      '--repo',
      repo,
      '--json',
      'body',
      '-q',
      '.body',
    ]);
    return result.ok ? result.stdout.trim() : '';
  }

  Future<void> closeIssue(int number, String comment) async {
    await _quiet([
      'issue',
      'edit',
      '$number',
      '--repo',
      repo,
      '--remove-label',
      'ready-for-agent',
    ]);
    await _quiet([
      'issue',
      'close',
      '$number',
      '--repo',
      repo,
      '--comment',
      comment,
    ]);
  }

  Future<void> relabelForHuman(int number) => _quiet([
    'issue',
    'edit',
    '$number',
    '--repo',
    repo,
    '--remove-label',
    'ready-for-agent',
    '--add-label',
    'ready-for-human',
  ]);

  Future<void> commentOnIssue(int number, String body) =>
      _quiet(['issue', 'comment', '$number', '--repo', repo, '--body', body]);

  /// Removes `ready-for-agent` without closing or relabeling. Used to take an
  /// umbrella PRD out of the agent queue: it is not a work item and is closed
  /// by its PR's `Closes #parent`, so it should never re-enter selection.
  Future<void> dropAgentLabel(int number) => _quiet([
    'issue',
    'edit',
    '$number',
    '--repo',
    repo,
    '--remove-label',
    'ready-for-agent',
  ]);

  Future<String?> createDraftPr({
    required String base,
    required String head,
    required String title,
    required String body,
  }) async {
    final created = await _proc.run('gh', [
      'pr',
      'create',
      '--repo',
      repo,
      '--base',
      base,
      '--head',
      head,
      '--draft',
      '--title',
      title,
      '--body',
      body,
    ]);
    if (created.ok) return created.stdout.trim();
    final existing = await _proc.run('gh', [
      'pr',
      'view',
      head,
      '--repo',
      repo,
      '--json',
      'url',
      '-q',
      '.url',
    ]);
    final url = existing.stdout.trim();
    return existing.ok && url.isNotEmpty ? url : null;
  }

  Future<void> commentOnPr(String ref, String body) =>
      _quiet(['pr', 'comment', ref, '--repo', repo, '--body', body]);

  Future<void> markPrReady(String ref) =>
      _quiet(['pr', 'ready', ref, '--repo', repo]);

  Future<void> editPr(String ref, {String? base, String? title}) => _quiet([
    'pr',
    'edit',
    ref,
    '--repo',
    repo,
    if (base != null) ...['--base', base],
    if (title != null) ...['--title', title],
  ]);

  Future<void> _quiet(List<String> arguments) async {
    await _proc.run('gh', arguments);
  }
}
