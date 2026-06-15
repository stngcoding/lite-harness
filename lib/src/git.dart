import 'proc.dart';

class GitOps {
  GitOps(this._proc);

  final ProcessRunner _proc;

  Future<String> _out(List<String> arguments) async =>
      (await _proc.run('git', arguments)).stdout.trim();

  Future<bool> _succeeds(List<String> arguments) async =>
      (await _proc.run('git', arguments)).ok;

  /// Tooling artifacts rewritten by hooks while the loop runs; they must
  /// never ride along in issue commits or count as implementation drift. The
  /// bundled review agents the harness drops into the target repo are here too
  /// (mirrors `AgentInstaller.bundledAgents`): they are harness scaffolding,
  /// not part of any issue's slice.
  static const artifactExcludes = [
    '.remember',
    '.claude/agents/diff-verifier.md',
    '.claude/agents/pr-review-lens.md',
    '.claude/agents/pr-review-haiku.md',
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
    await _proc.run('git', ['fetch', 'origin', base, '--quiet']);
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

  Future<String> currentBranch() => _out(['rev-parse', '--abbrev-ref', 'HEAD']);

  Future<bool> commitAll(String message) async {
    await _proc.run('git', ['add', '-A', '--', ..._workPathspecs]);
    return _succeeds(['commit', '-q', '-m', message]);
  }

  Future<void> tagFail(int issueNumber) async {
    await _proc.run('git', ['tag', '-f', 'ralph-fail/$issueNumber', 'HEAD']);
  }

  Future<void> resetHard(String ref) async {
    await _proc.run('git', ['reset', '--hard', ref]);
  }

  Future<bool> pushBranch(String branch) =>
      _succeeds(['push', '-u', 'origin', branch]);

  Future<int> aheadOf(String base) async {
    final count = await _out(['rev-list', '--count', 'origin/$base..HEAD']);
    return int.tryParse(count) ?? 0;
  }
}
