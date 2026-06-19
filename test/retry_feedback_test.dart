import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('previousAttemptBlock', () {
    test('returns an empty block when the diff is empty', () {
      expect(previousAttemptBlock('', 'irrelevant stat'), isEmpty);
      expect(previousAttemptBlock('   \n  ', 'irrelevant stat'), isEmpty);
    });

    test('inlines the full diff when it is small enough', () {
      const diff =
          'diff --git a/lib/a.dart b/lib/a.dart\n'
          '@@ -1 +1 @@\n'
          '-old\n'
          '+new';
      final block = previousAttemptBlock(diff, 'a.dart | 2 +-');
      expect(block, contains('```diff'));
      expect(block, contains('+new'));
      expect(block, isNot(contains('a.dart | 2 +-')));
      expect(block, contains('do NOT just repeat'));
    });

    test('falls back to the diffstat when the diff exceeds maxLines', () {
      final diff = List.generate(50, (i) => '+line $i').join('\n');
      const stat = ' lib/a.dart | 50 ++++';
      final block = previousAttemptBlock(diff, stat, maxLines: 10);
      expect(block, contains('diffstat'));
      expect(block, contains(stat.trim()));
      expect(block, isNot(contains('+line 0')));
    });
  });
}
