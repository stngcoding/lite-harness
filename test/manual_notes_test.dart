import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('manualNotes', () {
    test('extracts the text after each bare MANUAL: line', () {
      const t = '''
### Code review
No blocking issues.

MANUAL: Confirm the empty-state illustration renders on a real device.
MANUAL: Verify the export finishes under 2s with 1000 rows.

VERDICT: PASS''';
      expect(manualNotes(t), [
        'Confirm the empty-state illustration renders on a real device.',
        'Verify the export finishes under 2s with 1000 rows.',
      ]);
    });

    test('ignores prose that merely mentions the format', () {
      const t =
          'Emit a MANUAL: line for each criterion a human must check.\n'
          'I found nothing needing manual checks.';
      expect(manualNotes(t), isEmpty);
    });

    test('matches a trimmed MANUAL: line and drops blank notes', () {
      const t = '  MANUAL:  Tap through the onboarding flow.  \nMANUAL:   \n';
      expect(manualNotes(t), ['Tap through the onboarding flow.']);
    });

    test('collapses duplicate notes, preserving first-seen order', () {
      const t = 'MANUAL: Check A\nMANUAL: Check B\nMANUAL: Check A';
      expect(manualNotes(t), ['Check A', 'Check B']);
    });

    test('returns empty for a transcript with no notes', () {
      expect(manualNotes('VERDICT: FAIL\n- a.dart:1 broken'), isEmpty);
      expect(manualNotes(''), isEmpty);
    });
  });
}
