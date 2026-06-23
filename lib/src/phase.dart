import 'ansi.dart';

/// The operational stages of one harness run, in execution order. Each carries
/// a label and color so a human skimming a long AFK run sees the active stage at
/// a glance. The harness pipeline — distinct from an issue's own `## Phase`
/// metadata (see `phaseOf` in issue.dart).
enum HarnessPhase {
  select('SELECT'),
  checkout('CHECKOUT'),
  classify('CLASSIFY'),
  implement('IMPLEMENT'),
  commit('COMMIT'),
  analyze('ANALYZE'),
  test('TEST'),
  review('REVIEW'),
  pr('PR');

  const HarnessPhase(this.label);

  final String label;

  String _color(Ansi ansi) => switch (this) {
    HarnessPhase.select || HarnessPhase.checkout => ansi.cyan(label),
    HarnessPhase.classify => ansi.cyan(label),
    HarnessPhase.implement => ansi.blue(label),
    HarnessPhase.commit => ansi.magenta(label),
    HarnessPhase.analyze || HarnessPhase.test => ansi.yellow(label),
    HarnessPhase.review => ansi.magenta(label),
    HarnessPhase.pr => ansi.green(label),
  };

  /// A one-line active-stage marker, e.g. `▶ IMPLEMENT — #123 fix login`.
  /// The arrow is bold and the label colored; [detail] (if any) is dimmed.
  String marker(Ansi ansi, [String? detail]) {
    final head = '${ansi.bold('▶')} ${_color(ansi)}';
    return detail == null ? head : '$head ${ansi.dim('— $detail')}';
  }
}
