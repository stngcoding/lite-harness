import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('AgentInstaller.ensureInstalled', () {
    test('writes every bundled agent when the target has none', () async {
      final root = await Directory.systemTemp.createTemp('lh-agent-fresh');
      addTearDown(() => root.delete(recursive: true));

      final installer = AgentInstaller(
        loadBundled: (name) async => 'BODY OF $name',
      );
      final installed = await installer.ensureInstalled(repoRoot: root);

      expect(installed, AgentInstaller.bundledAgents);
      for (final name in AgentInstaller.bundledAgents) {
        final written = File('${root.path}/${AgentInstaller.pathFor(name)}');
        expect(written.existsSync(), isTrue, reason: name);
        expect(written.readAsStringSync(), 'BODY OF $name');
      }
    });

    test('never overwrites an agent the target already ships', () async {
      final root = await Directory.systemTemp.createTemp('lh-agent-keep');
      addTearDown(() => root.delete(recursive: true));
      final existing = File('${root.path}/${AgentInstaller.relativePath}')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('TARGET OWNS THIS');

      final installer = AgentInstaller(
        loadBundled: (name) async => 'BODY OF $name',
      );
      final installed = await installer.ensureInstalled(repoRoot: root);

      // The orchestrator the target owns is preserved and not reinstalled; the
      // absent worker agents are still dropped in.
      expect(installed, isNot(contains('diff-verifier')));
      expect(installed, contains('pr-review-lens'));
      expect(installed, contains('pr-review-haiku'));
      expect(existing.readAsStringSync(), 'TARGET OWNS THIS');
    });

    test('writes nothing when every bundled agent is present', () async {
      final root = await Directory.systemTemp.createTemp('lh-agent-full');
      addTearDown(() => root.delete(recursive: true));
      for (final name in AgentInstaller.bundledAgents) {
        File('${root.path}/${AgentInstaller.pathFor(name)}')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('owned $name');
      }

      final installed = await AgentInstaller(
        loadBundled: (name) async => 'BODY OF $name',
      ).ensureInstalled(repoRoot: root);

      expect(installed, isEmpty);
    });

    test('the packaged defaults resolve: orchestrator carries the verdict '
        'protocol and the workers carry their model tiers', () async {
      final root = await Directory.systemTemp.createTemp('lh-agent-default');
      addTearDown(() => root.delete(recursive: true));

      final installed = await AgentInstaller().ensureInstalled(repoRoot: root);

      expect(installed, AgentInstaller.bundledAgents);

      final orchestrator = File(
        '${root.path}/${AgentInstaller.relativePath}',
      ).readAsStringSync();
      expect(orchestrator, contains('name: diff-verifier'));
      expect(orchestrator, contains('VERDICT: PASS'));
      expect(orchestrator, contains('VERDICT: FAIL'));

      final lens = File(
        '${root.path}/${AgentInstaller.pathFor('pr-review-lens')}',
      ).readAsStringSync();
      expect(lens, contains('model: sonnet'));

      final helper = File(
        '${root.path}/${AgentInstaller.pathFor('pr-review-haiku')}',
      ).readAsStringSync();
      expect(helper, contains('model: haiku'));
    });
  });
}
