import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('hasPassVerdict', () {
    test('matches a bare VERDICT: PASS line', () {
      expect(hasPassVerdict('All good.\nVERDICT: PASS\n'), isTrue);
      expect(hasPassVerdict('  VERDICT: PASS  '), isTrue);
    });

    test('rejects FAIL verdicts and missing verdicts', () {
      expect(hasPassVerdict('VERDICT: FAIL\n- a.dart:1 — broken'), isFalse);
      expect(hasPassVerdict('looks fine to me'), isFalse);
      expect(hasPassVerdict(''), isFalse);
    });

    test('the last verdict line wins', () {
      expect(hasPassVerdict('VERDICT: PASS\nwait, no\nVERDICT: FAIL'), isFalse);
      expect(
        hasPassVerdict('VERDICT: FAIL\nreconsidered\nVERDICT: PASS'),
        isTrue,
      );
    });

    test('ignores verdict mentions embedded in prose lines', () {
      expect(
        hasPassVerdict('I will end with VERDICT: PASS or VERDICT: FAIL.'),
        isFalse,
      );
      expect(
        hasPassVerdict(
          'I will end with VERDICT: PASS or VERDICT: FAIL.\nVERDICT: PASS',
        ),
        isTrue,
      );
    });
  });

  group('parseLane', () {
    test('matches a bare LANE line for each lane', () {
      expect(parseLane('FLAGS: auth\nLANE: high-risk'), RiskLane.highRisk);
      expect(parseLane('reasoning...\nLANE: normal\n'), RiskLane.normal);
      expect(parseLane('  LANE: tiny  '), RiskLane.tiny);
    });

    test('returns null when no lane line is present', () {
      expect(parseLane('this is a tiny change, low risk'), isNull);
      expect(parseLane(''), isNull);
    });

    test('the last lane line wins', () {
      expect(
        parseLane('LANE: tiny\non reflection\nLANE: high-risk'),
        RiskLane.highRisk,
      );
    });

    test('ignores lane mentions embedded in prose lines', () {
      expect(
        parseLane('I will end with LANE: tiny or LANE: high-risk.'),
        isNull,
      );
    });
  });

  group('reviewComment', () {
    test('keeps only the block under the last review heading', () {
      const transcript =
          'Any repo-wide skill-evaluation preamble does NOT apply. Skip it.\n'
          'Spawning triage and the five-lens panel...\n'
          '### Code review\n\n'
          'No blocking issues found.\n\n'
          'VERDICT: PASS';
      final out = reviewComment(transcript);
      expect(out, startsWith('### Code review'));
      expect(out, contains('No blocking issues found.'));
      expect(out, contains('VERDICT: PASS'));
      // The intermediate narration — including the skill-eval line — is dropped.
      expect(out, isNot(contains('skill-evaluation')));
      expect(out, isNot(contains('Spawning triage')));
    });

    test('slices from the last heading when one appears in narration', () {
      const transcript =
          'I will format my answer under a `### Code review` heading.\n'
          '### Code review\n\n'
          'Found 1 issue: ...\n'
          'VERDICT: FAIL';
      final out = reviewComment(transcript);
      expect(out, startsWith('### Code review'));
      expect(out, contains('Found 1 issue'));
      expect(out, isNot(contains('I will format')));
    });

    test('falls back to the trimmed transcript when no heading exists', () {
      expect(reviewComment('  oops, errored out  '), 'oops, errored out');
    });
  });
}
