import 'dart:io';

/// ANSI styling for live output. Pure string helpers so rendering stays
/// unit-testable: `Ansi(enabled: false)` for plain strings, `Ansi.forStdout()`
/// in production. Color is off when stdout is not a terminal or `NO_COLOR` is
/// set (https://no-color.org/).
class Ansi {
  const Ansi({required this.enabled});

  factory Ansi.forStdout() => Ansi(
    enabled:
        stdout.hasTerminal && !Platform.environment.containsKey('NO_COLOR'),
  );

  final bool enabled;

  String _wrap(String code, String text) =>
      enabled ? '\x1B[${code}m$text\x1B[0m' : text;

  String red(String t) => _wrap('31', t);
  String green(String t) => _wrap('32', t);
  String yellow(String t) => _wrap('33', t);
  String blue(String t) => _wrap('34', t);
  String magenta(String t) => _wrap('35', t);
  String cyan(String t) => _wrap('36', t);
  String dim(String t) => _wrap('2', t);
  String bold(String t) => _wrap('1', t);
  String dimCyan(String t) => _wrap('2;36', t);
  String dimMagenta(String t) => _wrap('2;35', t);
}
