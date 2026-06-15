import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('scopedTestFiles', () {
    test('keeps changed test files as-is', () {
      expect(scopedTestFiles(['test/features/holdings_cubit_test.dart']), {
        'test/features/holdings_cubit_test.dart',
      });
    });

    test('maps a changed lib file to its mirror test', () {
      expect(scopedTestFiles(['lib/features/holdings_cubit.dart']), {
        'test/features/holdings_cubit_test.dart',
      });
    });

    test('combines lib mirrors and changed tests, de-duplicated', () {
      expect(
        scopedTestFiles([
          'lib/a/foo.dart',
          'test/a/foo_test.dart',
          'lib/b/bar.dart',
        ]),
        {'test/a/foo_test.dart', 'test/b/bar_test.dart'},
      );
    });

    test('ignores non-dart, non-test, and out-of-tree paths', () {
      expect(
        scopedTestFiles([
          'pubspec.yaml',
          'README.md',
          'test/fixtures/data.json',
          'tool/gen.dart',
        ]),
        isEmpty,
      );
    });
  });
}
