import 'dart:io';

/// A *leading* YAML frontmatter block. Non-greedy so it stops at the first
/// closing fence, anchored at the start so a `---` later in the body is safe.
final _frontmatter = RegExp(r'^---\r?\n.*?\r?\n---[ \t]*\r?\n', dotAll: true);

/// Strips a leading YAML frontmatter block from a rule file: its `--- … ---`
/// (e.g. `paths:`) is meaningless once flattened into a system prompt. A body
/// without leading frontmatter is returned unchanged.
String stripFrontmatter(String content) =>
    content.replaceFirst(_frontmatter, '');

/// Builds the implementer system-prompt blob from target-repo rule files:
/// frontmatter stripped, non-empty bodies concatenated in filename order under a
/// short header. `''` when nothing to inject, so the caller omits the flag.
String buildRulesSystemPrompt(Map<String, String> files) {
  final names = files.keys.toList()..sort();
  final sections = <String>[];
  for (final name in names) {
    final body = stripFrontmatter(files[name]!).trim();
    if (body.isEmpty) continue;
    sections.add('# Rule: $name\n\n$body');
  }
  if (sections.isEmpty) return '';
  return 'The target repository defines the following project rules. '
      'Follow them exactly while implementing.\n\n'
      '${sections.join('\n\n---\n\n')}';
}

/// The implementer system-prompt blob plus the rule filenames that actually
/// contributed to it (non-empty after frontmatter strip), so the harness can
/// report which rules it injected.
class RulesPrompt {
  const RulesPrompt(this.text, this.files);

  /// The `--append-system-prompt` blob, `''` when nothing is injected.
  final String text;

  /// Rule filenames injected, sorted. Empty when [text] is `''`.
  final List<String> files;
}

/// Reads the target repo's root `<repoRoot>/.claude/rules/*.md` (non-recursive,
/// `.md` only) and builds the implementer blob. [repoRoot] defaults to the cwd
/// (the harness runs inside the target clone). Nested `.claude/rules/**` keep
/// their `paths:` scoping and are not loaded. Empty when the dir is absent.
Future<RulesPrompt> loadRulesSystemPrompt({Directory? repoRoot}) async {
  final root = repoRoot ?? Directory.current;
  final dir = Directory('${root.path}/.claude/rules');
  if (!await dir.exists()) return const RulesPrompt('', []);
  final files = <String, String>{};
  await for (final entry in dir.list(followLinks: false)) {
    if (entry is File && entry.path.endsWith('.md')) {
      files[entry.uri.pathSegments.last] = await entry.readAsString();
    }
  }
  final included = (files.keys.toList()..sort())
      .where((name) => stripFrontmatter(files[name]!).trim().isNotEmpty)
      .toList();
  return RulesPrompt(buildRulesSystemPrompt(files), included);
}
