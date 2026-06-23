import 'dart:io';

import 'proc.dart';

class GitOps {
  GitOps(this._proc, {this.workingDirectory});

  final ProcessRunner _proc;

  /// The repo this instance operates in. `null` = the process cwd; a parallel
  /// worker passes its per-issue worktree path so its git acts on that tree.
  final String? workingDirectory;

  Future<String> _out(List<String> arguments) async => (await _proc.run(
    'git',
    arguments,
    workingDirectory: workingDirectory,
  )).stdout.trim();

  Future<bool> _succeeds(List<String> arguments) async => (await _proc.run(
    'git',
    arguments,
    workingDirectory: workingDirectory,
  )).ok;

  /// Harness scaffolding that must never ride along in an issue commit or count
  /// as drift: hook-rewritten artifacts, the bundled review agents the harness
  /// drops in (mirrors `AgentInstaller.bundledAgents`), and the `.dartralph/`
  /// state (traces, cost ledger, worktrees, logs).
  static const artifactExcludes = [
    '.remember',
    '.claude/agents/diff-verifier.md',
    '.claude/agents/pr-review-lens.md',
    '.claude/agents/pr-review-haiku.md',
    '.claude/agents/intake.md',
    '.dartralph/traces.jsonl',
    '.dartralph/calls.jsonl',
    '.dartralph/worktrees',
    '.dartralph/logs',
  ];

  static final List<String> _workPathspecs = [
    '.',
    for (final path in artifactExcludes) ':(exclude)$path',
  ];

  Future<bool> hasDrift() async => (await _out([
    'status',
    '--porcelain',
    '--',
    ..._workPathspecs,
  ])).isNotEmpty;

  Future<String?> parkDrift() async {
    if (!await hasDrift()) return null;
    final epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final name = 'ralph-parked-$epoch';
    final stashed = await _succeeds(['stash', 'push', '-u', '-m', name]);
    return stashed ? name : null;
  }

  Future<void> fetch(String base) async {
    await _proc.run('git', [
      'fetch',
      'origin',
      base,
      '--quiet',
    ], workingDirectory: workingDirectory);
  }

  Future<bool> branchExists(String branch) =>
      _succeeds(['show-ref', '--verify', '--quiet', 'refs/heads/$branch']);

  Future<List<String>> localBranches() async {
    final out = await _out(['branch', '--format=%(refname:short)']);
    if (out.isEmpty) return const [];
    return out
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  Future<bool> checkout(String branch) => _succeeds(['checkout', branch]);

  Future<bool> checkoutNew(String branch, String from) async {
    if (await _succeeds(['checkout', '-B', branch, from])) return true;
    return _succeeds(['checkout', '-b', branch]);
  }

  Future<String> head() => _out(['rev-parse', 'HEAD']);

  /// Repo-relative paths that changed between [baseline] and `HEAD` — the files
  /// a slice's commit touched, used to scope its test gate.
  Future<List<String>> changedFiles(String baseline) async {
    final out = await _out(['diff', '--name-only', baseline, 'HEAD']);
    if (out.isEmpty) return const [];
    return out
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// The full patch of the slice's commit range ([baseline]..HEAD) — fed back to
  /// the implementer on a retry so it sees what its last attempt changed.
  Future<String> diff(String baseline) => _out(['diff', baseline, 'HEAD']);

  /// The `--stat` summary (files + ±counts) of [baseline]..HEAD — the bounded
  /// fallback used when the full [diff] is too large to inject wholesale.
  Future<String> diffStat(String baseline) =>
      _out(['diff', '--stat', baseline, 'HEAD']);

  Future<String> currentBranch() => _out(['rev-parse', '--abbrev-ref', 'HEAD']);

  Future<bool> commitAll(String message) async {
    await stageAll();
    return commitStaged(message);
  }

  /// Stages every changed work-path (artifacts excluded) without committing, so
  /// the secret-scan can inspect [stagedDiff] before [commitStaged] lands.
  Future<void> stageAll() async {
    await _proc.run('git', [
      'add',
      '-A',
      '--',
      ..._workPathspecs,
    ], workingDirectory: workingDirectory);
  }

  Future<bool> commitStaged(String message) =>
      _succeeds(['commit', '-q', '-m', message]);

  /// The staged patch (`git diff --cached`) — what [stageAll] queued, scanned
  /// for secrets before [commitStaged].
  Future<String> stagedDiff() => _out(['diff', '--cached']);

  /// Adds a linked worktree at `.dartralph/worktrees/<branch>` on a fresh
  /// [branch] cut from [fromRef], so a parallel worker edits an isolated tree.
  /// Returns the path, or null if it could not be created. Self-healing: a
  /// crashed run leaves a stale branch + directory that fails `worktree add -b`,
  /// so on a first failure we clear the stale state for this path and retry once.
  Future<String?> createWorktree(String branch, String fromRef) async {
    final path = '.dartralph/worktrees/$branch';
    if (await _addWorktree(branch, path, fromRef)) return path;
    await removeWorktree(path);
    await deleteBranch(branch);
    _deleteDir(path);
    return await _addWorktree(branch, path, fromRef) ? path : null;
  }

  Future<bool> _addWorktree(String branch, String path, String fromRef) =>
      _succeeds(['worktree', 'add', '-b', branch, path, fromRef]);

  /// Removes a stale orphan directory `git worktree` no longer tracks. Resolved
  /// against the same [workingDirectory] git runs in, so relative paths line up.
  void _deleteDir(String path) {
    final full = workingDirectory == null ? path : '$workingDirectory/$path';
    final dir = Directory(full);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  Future<void> removeWorktree(String path) async {
    await _succeeds(['worktree', 'remove', '--force', path]);
    await _succeeds(['worktree', 'prune']);
  }

  Future<bool> cherryPick(String sha) => _succeeds(['cherry-pick', sha]);

  Future<void> cherryPickAbort() async {
    await _succeeds(['cherry-pick', '--abort']);
  }

  /// Merges [ref] into the current branch (`--no-ff` by default so a diamond
  /// base keeps a merge commit). Returns false on conflict — the caller then
  /// [mergeAbort]s and hands the integration off to a human.
  Future<bool> merge(String ref, {bool noFf = true}) =>
      _succeeds(['merge', if (noFf) '--no-ff', '--no-edit', ref]);

  Future<void> mergeAbort() async {
    await _succeeds(['merge', '--abort']);
  }

  Future<bool> deleteBranch(String branch) =>
      _succeeds(['branch', '-D', branch]);

  Future<void> tagFail(int issueNumber) async {
    await _proc.run('git', [
      'tag',
      '-f',
      'ralph-fail/$issueNumber',
      'HEAD',
    ], workingDirectory: workingDirectory);
  }

  Future<void> resetHard(String ref) async {
    await _proc.run('git', [
      'reset',
      '--hard',
      ref,
    ], workingDirectory: workingDirectory);
  }

  Future<bool> pushBranch(String branch) =>
      _succeeds(['push', '-u', 'origin', branch]);

  Future<int> aheadOf(String base) async {
    final count = await _out(['rev-list', '--count', 'origin/$base..HEAD']);
    return int.tryParse(count) ?? 0;
  }
}
