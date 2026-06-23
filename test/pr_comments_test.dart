import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('secretBlockComment', () {
    test('lists each finding as a bullet and explains remediation', () {
      final out = secretBlockComment(['aws key in lib/a.dart', 'token in b']);
      expect(out, contains('🔒 **Commit blocked'));
      expect(out, contains('- aws key in lib/a.dart'));
      expect(out, contains('- token in b'));
      expect(out, contains('relabel'));
    });
  });

  group('manualSection', () {
    test('renders bare MANUAL: notes as an unchecked checklist', () {
      const t = 'MANUAL: Check the empty state on device\nVERDICT: PASS';
      expect(
        manualSection(t),
        '\n\n## Manual verification (needs a human)\n'
        '- [ ] Check the empty state on device',
      );
    });

    test('is empty when the transcript has no notes', () {
      expect(manualSection('VERDICT: PASS'), isEmpty);
    });
  });

  group('structuralSection', () {
    test(
      'renders STRUCTURAL: notes as a plain-bullet maintainability list',
      () {
        const t =
            'STRUCTURAL: Collapse the two export branches into one path.\n'
            'STRUCTURAL: Drop the unused LegacyAdapter wrapper.\n'
            'VERDICT: PASS';
        expect(
          structuralSection(t),
          '\n\n## Maintainability review (structural)\n'
          '- Collapse the two export branches into one path.\n'
          '- Drop the unused LegacyAdapter wrapper.',
        );
      },
    );

    test(
      'uses plain bullets, not a checklist (these are not required fixes)',
      () {
        const t = 'STRUCTURAL: Merge the duplicate parsers.\nVERDICT: PASS';
        expect(structuralSection(t), isNot(contains('- [ ]')));
      },
    );

    test('is empty when the transcript has no structural notes', () {
      expect(structuralSection('MANUAL: check device\nVERDICT: PASS'), isEmpty);
    });
  });

  group('gateEvidence', () {
    test('wraps each labelled tail in a collapsible block', () {
      final out = gateEvidence([
        ('analyze', 'No issues found!'),
        ('test', 'All tests passed!'),
      ]);
      expect(out, contains('<details><summary>Gate evidence'));
      expect(out, contains('`fvm flutter analyze`'));
      expect(out, contains('No issues found!'));
      expect(out, contains('`fvm flutter test`'));
      expect(out, contains('All tests passed!'));
    });

    test('is empty when no gate ran', () {
      expect(gateEvidence([]), isEmpty);
    });
  });

  group('failComment', () {
    test('reports the verdict, recovery tag, and log tails', () {
      final out = failComment(
        42,
        analyzeOk: false,
        testOk: true,
        logs: '==> /tmp/a.log <==\nboom',
        implementSummary: '\n\nImplement: did a thing.',
      );
      expect(out, contains('AFK verify FAILED (analyze=0 test=1)'));
      expect(out, contains('Implement: did a thing.'));
      expect(out, contains('ralph-fail/42'));
      expect(out, contains('boom'));
      expect(out, isNot(contains('likely too large')));
    });

    test('adds the too-large advisory only when context-starved', () {
      final out = failComment(
        7,
        analyzeOk: true,
        testOk: false,
        logs: 'x',
        contextStarved: true,
      );
      expect(out, contains('likely too large'));
      expect(out, contains('<15% free'));
    });
  });

  group('ciHandoffComment', () {
    test('explains gates passed but the named reason left it a draft', () {
      final out = ciHandoffComment('remote CI stayed red');
      expect(out, contains('🛠️ **CI watch'));
      expect(out, contains('remote CI stayed red'));
      expect(out, contains('nothing was rolled back'));
    });
  });

  group('conflict comments', () {
    test('mergeConflictComment names the slice and its blocker', () {
      final out = mergeConflictComment(12, 9);
      expect(out, contains('Could not start #12'));
      expect(out, contains('blocker #9'));
    });

    test('integrationConflictComment names the PRD and conflicting slice', () {
      final out = integrationConflictComment(3, 5);
      expect(out, contains('PRD #3'));
      expect(out, contains('slice #5'));
      expect(out, contains('.dartralph/worktrees/'));
    });
  });
}
