import 'proc.dart';

class GitOps {
  GitOps(this._proc, {this.workingDirectory});

  final ProcessRunner _proc;

  /// The repo this instance operates in. `null` = the harness process's own cwd
  /// (the canonical worktree); a parallel worker passes its per-issue worktree
  /// path so its git commands act on that tree, not the shared one.
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

  /// Tooling artifacts rewritten by hooks while the loop runs; they must
  /// never ride along in issue commits or count as implementation drift. The
  /// bundled review agents the harness drops into the target repo are here too
  /// (mirrors `AgentInstaller.bundledAgents`): they are harness scaffolding,
  /// not part of any issue's slice. `.dartralph/traces.jsonl` (cross-run
  /// friction) and `.dartralph/calls.jsonl` (the per-call cost ledger) are
  /// harness state, never a slice artifact.
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

  /// The full patch text of the slice's commit range ([baseline]..HEAD) — fed
  /// back to the implementer on a retry so it sees what its previous attempt
  /// actually changed instead of re-deriving blind. Artifacts are already
  /// excluded by [commitAll], so the committed range carries none.
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

  /// Stages every changed work-path (artifacts excluded) without committing —
  /// the seam the secret-scan inspects via [stagedDiff] before the commit is
  /// allowed to land.
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
  /// Returns the path, or null if the worktree could not be created.
  Future<String?> createWorktree(String branch, String fromRef) async {
    final path = '.dartralph/worktrees/$branch';
    final ok = await _succeeds([
      'worktree',
      'add',
      '-b',
      branch,
      path,
      fromRef,
    ]);
    return ok ? path : null;
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
