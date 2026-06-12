import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('Ansi', () {
    test('wraps text in SGR codes when enabled', () {
      const ansi = Ansi(enabled: true);
      expect(ansi.green('ok'), '\x1B[32mok\x1B[0m');
      expect(ansi.red('no'), '\x1B[31mno\x1B[0m');
      expect(ansi.bold('hi'), '\x1B[1mhi\x1B[0m');
    });

    test('returns plain text when disabled', () {
      const ansi = Ansi(enabled: false);
      expect(ansi.green('ok'), 'ok');
      expect(ansi.dim('x'), 'x');
    });
  });

  group('HarnessPhase.marker', () {
    const plain = Ansi(enabled: false);

    test('renders the bold arrow and label', () {
      expect(HarnessPhase.implement.marker(plain), '▶ IMPLEMENT');
    });

    test('appends an em-dash detail when given', () {
      expect(HarnessPhase.commit.marker(plain, '#7'), '▶ COMMIT — #7');
    });

    test('each stage colors its label distinctly when enabled', () {
      const ansi = Ansi(enabled: true);
      expect(HarnessPhase.analyze.marker(ansi), contains('\x1B[33mANALYZE'));
      expect(HarnessPhase.pr.marker(ansi), contains('\x1B[32mPR'));
    });
  });
}
