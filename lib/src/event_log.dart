import 'dart:io';

/// Default path for the per-run event log. Fixed under `/tmp` to sit beside the
/// harness's other run artifacts (`/tmp/ralph-analyze.log`, `/tmp/ralph-test.log`).
const eventLogPath = '/tmp/ralph-events.log';

/// Append-only, machine-readable record of one run's event sequence. Each
/// [event] writes `<ISO8601> <NAME> [prd=N] [issue=N] [detail]`, flushed
/// synchronously so the trail survives a crash or `kill` mid-run. Truncated on
/// creation, so it always holds just the latest run.
class EventLog {
  EventLog([this.path = eventLogPath]) {
    File(path).writeAsStringSync('');
  }

  final String path;

  void event(String name, {int? prd, int? issue, String? detail}) {
    final fields = <String>[
      DateTime.now().toIso8601String(),
      name,
      if (prd != null) 'prd=$prd',
      if (issue != null) 'issue=$issue',
      if (detail != null && detail.isNotEmpty) detail,
    ];
    File(
      path,
    ).writeAsStringSync('${fields.join(' ')}\n', mode: FileMode.append);
  }
}
