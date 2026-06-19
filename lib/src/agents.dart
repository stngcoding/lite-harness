import 'dart:io';
import 'dart:isolate';

/// Ships the Claude Code agents the harness's review gate depends on.
///
/// The authoritative `claude --agent diff-verifier` gate needs an agent named
/// `diff-verifier` to exist where `claude` runs; in PR mode that orchestrator
/// fans the review out to two worker agents (`pr-review-lens`, the independent
/// panel reviewers, and `pr-review-haiku`, the triage/scoring helper). The
/// harness bundles all three and drops each into the target repo's
/// `.claude/agents/` when it is absent, so a fresh clone is not silently failed
/// by every gate.
///
/// An existing agent is never overwritten: a target that ships its own tuned
/// reviewer keeps it. Each written path is excluded from drift detection (see
/// [GitOps.artifactExcludes]) so it never rides along in an issue commit.
class AgentInstaller {
  AgentInstaller({Future<String> Function(String name)? loadBundled})
    : _loadBundled = loadBundled ?? _resolveBundled;

  final Future<String> Function(String name) _loadBundled;

  /// Agent names the harness bundles, in install order. `diff-verifier` is the
  /// gate's entry point; the rest are the worker roles its PR pipeline fans out
  /// to. Mirrored by [GitOps.artifactExcludes].
  static const bundledAgents = [
    'diff-verifier',
    'pr-review-lens',
    'pr-review-haiku',
    'intake',
  ];

  /// Where an agent lives inside a target repo, relative to its root.
  static String pathFor(String name) => '.claude/agents/$name.md';

  /// The orchestrator agent's path — the gate's entry point.
  static String get relativePath => pathFor('diff-verifier');

  /// Writes every bundled agent absent from [repoRoot] (default: the current
  /// directory), leaving any agent the target already ships untouched. Returns
  /// the names it just wrote, in install order.
  Future<List<String>> ensureInstalled({Directory? repoRoot}) async {
    final root = repoRoot ?? Directory.current;
    final written = <String>[];
    for (final name in bundledAgents) {
      final target = File('${root.path}/${pathFor(name)}');
      if (target.existsSync()) continue;
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(await _loadBundled(name));
      written.add(name);
    }
    return written;
  }

  static Future<String> _resolveBundled(String name) async {
    // The harness always runs from source (never AOT-compiled), so the package
    // URI always resolves to lib/agents/<name>.md.
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:dartralph/agents/$name.md'),
    );
    return File.fromUri(uri!).readAsString();
  }
}
