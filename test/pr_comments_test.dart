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

  group('prSkipExplanation', () {
    test('nothing-to-ship (no commits, no open subs) flags a human', () {
      final out = prSkipExplanation(
        prd: 367,
        ahead: 0,
        base: 'main',
        branch: '367-feed',
        openSubs: const [],
      );
      expect(out.needsHuman, isTrue);
      expect(out.text, contains('PRD #367'));
      expect(out.text, contains('nothing to ship'));
      expect(out.text, contains('ralph-fail/<n>'));
      expect(out.text, contains('relabel `ready-for-agent`'));
    });

    test('open subs all ready-for-agent are mid-retry, not a human stall', () {
      final out = prSkipExplanation(
        prd: 5,
        ahead: 2,
        base: 'dev',
        branch: '5-x',
        openSubs: const [
          (number: 6, needsHuman: false),
          (number: 7, needsHuman: false),
        ],
      );
      expect(out.needsHuman, isFalse);
      expect(out.text, contains('2 sub-issue(s) still open'));
      expect(out.text, contains('#6, #7'));
      expect(out.text, contains('ready-for-agent'));
      expect(out.text, contains('retried automatically'));
      expect(out.text, isNot(contains('needs you')));
    });

    test('a ready-for-human sub flags a human and is listed apart', () {
      final out = prSkipExplanation(
        prd: 5,
        ahead: 1,
        base: 'dev',
        branch: '5-x',
        openSubs: const [
          (number: 6, needsHuman: false),
          (number: 8, needsHuman: true),
        ],
      );
      expect(out.needsHuman, isTrue);
      expect(out.text, contains('#6 still `ready-for-agent`'));
      expect(out.text, contains('#8 `ready-for-human`'));
      expect(out.text, contains('needs you'));
      expect(out.text, contains('Branch `5-x` holds 1 commit(s)'));
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

    test('restackCloseComment names the PRD and the re-stacked slice', () {
      final out = restackCloseComment(3, 5);
      expect(out, contains('PRD #3'));
      expect(out, contains('#5'));
      expect(out, contains('re-implemented'));
      expect(out, contains('analyze + scoped tests green'));
    });
  });
}
