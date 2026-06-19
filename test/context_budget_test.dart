import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('clampPrdBody', () {
    test('passes a body within budget through unchanged', () {
      final body = List.generate(10, (i) => 'line $i').join('\n');
      expect(clampPrdBody(body, 42, maxLines: 30), body);
    });

    test('keeps the head and points at the full issue when truncated', () {
      final body = List.generate(50, (i) => 'line $i').join('\n');
      final out = clampPrdBody(body, 42, maxLines: 30);
      expect(out, contains('line 0'));
      expect(out, contains('line 29'));
      expect(out, isNot(contains('line 30')));
      expect(out, contains('20 more line(s)'));
      expect(out, contains('gh issue view 42'));
    });
  });

  group('clampComments', () {
    String block(int i) => '**user$i** (t$i):\nbody $i\n';

    test('joins everything when within budget', () {
      final blocks = [for (var i = 0; i < 3; i++) block(i)];
      final out = clampComments(blocks, 7, keep: 5);
      expect(out, blocks.join('\n'));
      expect(out, isNot(contains('omitted')));
    });

    test('empty list yields an empty string', () {
      expect(clampComments(const [], 7), isEmpty);
    });

    test('keeps the newest comments and points at the rest', () {
      final blocks = [for (var i = 0; i < 8; i++) block(i)];
      final out = clampComments(blocks, 7, keep: 5);
      expect(out, contains('3 older comment(s) omitted'));
      expect(out, contains('gh issue view 7 --comments'));
      // The oldest three dropped; the newest five survive.
      expect(out, isNot(contains('body 2')));
      expect(out, contains('body 3'));
      expect(out, contains('body 7'));
    });
  });
}
