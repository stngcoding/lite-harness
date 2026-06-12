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
}
