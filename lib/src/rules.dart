import 'dart:io';

/// A *leading* YAML frontmatter block: `---` on the first line, its body, and a
/// closing `---` line. Non-greedy so it stops at the first closing fence, and
/// anchored at the start so a `---` later in the body is never touched.
final _frontmatter = RegExp(r'^---\r?\n.*?\r?\n---[ \t]*\r?\n', dotAll: true);

/// Strips a leading YAML frontmatter block from a rule file body. Claude Code
/// rule files carry `--- … ---` frontmatter (e.g. `paths:`), which is
/// meaningless once the body is flattened into a system prompt. A body without
/// leading frontmatter is returned unchanged.
String stripFrontmatter(String content) =>
    content.replaceFirst(_frontmatter, '');

/// Builds the implementer system-prompt append blob from target-repo rule files
/// keyed by filename. Frontmatter is stripped from each body and the (trimmed,
/// non-empty) bodies are concatenated in filename order under a short
/// instruction header. Returns `''` when there is nothing to inject, so the
/// caller can omit `--append-system-prompt` entirely.
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

/// Reads the target repo's root-level `<repoRoot>/.claude/rules/*.md`
/// (non-recursive, `.md` only) and builds the implementer system-prompt blob.
/// [repoRoot] defaults to [Directory.current] — the harness runs from inside
/// the target clone, same convention as `PromptLibrary.load`. Nested
/// `.claude/rules/**` files keep their `paths:` scoping intentionally and are
/// not loaded. Returns an empty [RulesPrompt] when the directory is absent or
/// holds no rules.
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
