import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

const _widgetRule = '''
---
paths: ["*.dart"]
---
# Flutter Widget Convention
Always define widgets as classes.''';

const _assetRule = '''
---
paths: ["*.dart"]
---
# Flutter Asset Convention
Use generated asset accessors.''';

void main() {
  group('stripFrontmatter', () {
    test('strips a leading --- … --- block', () {
      expect(
        stripFrontmatter(_widgetRule),
        '# Flutter Widget Convention\nAlways define widgets as classes.',
      );
    });

    test('a body without leading frontmatter is unchanged', () {
      const body = '# Title\nNo frontmatter here.';
      expect(stripFrontmatter(body), body);
    });

    test('a --- that is not at the start is left alone', () {
      const body = '# Title\n\n---\n\nmid-document rule.';
      expect(stripFrontmatter(body), body);
    });
  });

  group('buildRulesSystemPrompt', () {
    test('concatenates stripped bodies in filename order', () {
      final blob = buildRulesSystemPrompt({
        'widget.md': _widgetRule,
        'asset.md': _assetRule,
      });
      expect(blob, contains('Follow them exactly'));
      expect(blob, contains('# Rule: asset.md'));
      expect(blob, contains('# Rule: widget.md'));
      expect(blob, contains('Always define widgets as classes.'));
      expect(blob, contains('Use generated asset accessors.'));
      // Frontmatter is gone.
      expect(blob, isNot(contains('paths:')));
      // asset.md sorts before widget.md.
      expect(
        blob.indexOf('# Rule: asset.md'),
        lessThan(blob.indexOf('# Rule: widget.md')),
      );
    });

    test('empty map → empty blob', () {
      expect(buildRulesSystemPrompt({}), '');
    });

    test('frontmatter-only / blank bodies → empty blob', () {
      expect(
        buildRulesSystemPrompt({'a.md': '---\npaths: ["*.dart"]\n---\n'}),
        '',
      );
    });
  });

  group('loadRulesSystemPrompt', () {
    test('reads root-level .claude/rules/*.md, strips frontmatter', () async {
      final root = await Directory.systemTemp.createTemp('lh-rules');
      addTearDown(() => root.delete(recursive: true));
      final dir = Directory('${root.path}/.claude/rules')
        ..createSync(recursive: true);
      File('${dir.path}/widget.md').writeAsStringSync(_widgetRule);
      File('${dir.path}/asset.md').writeAsStringSync(_assetRule);

      final rules = await loadRulesSystemPrompt(repoRoot: root);
      expect(rules.text, contains('Always define widgets as classes.'));
      expect(rules.text, contains('Use generated asset accessors.'));
      expect(rules.text, isNot(contains('paths:')));
      expect(rules.files, ['asset.md', 'widget.md']);
    });

    test('missing directory → empty blob', () async {
      final root = await Directory.systemTemp.createTemp('lh-norules');
      addTearDown(() => root.delete(recursive: true));
      final rules = await loadRulesSystemPrompt(repoRoot: root);
      expect(rules.text, '');
      expect(rules.files, isEmpty);
    });

    test('ignores non-.md files and nested subdirectories', () async {
      final root = await Directory.systemTemp.createTemp('lh-rules-mixed');
      addTearDown(() => root.delete(recursive: true));
      final dir = Directory('${root.path}/.claude/rules')
        ..createSync(recursive: true);
      File('${dir.path}/widget.md').writeAsStringSync(_widgetRule);
      File('${dir.path}/notes.txt').writeAsStringSync('not a rule');
      Directory('${dir.path}/nested').createSync();
      File('${dir.path}/nested/scoped.md').writeAsStringSync(_assetRule);

      final rules = await loadRulesSystemPrompt(repoRoot: root);
      expect(rules.text, contains('Always define widgets as classes.'));
      expect(rules.text, isNot(contains('not a rule')));
      expect(rules.text, isNot(contains('Use generated asset accessors.')));
      expect(rules.files, ['widget.md']);
    });
  });
}
