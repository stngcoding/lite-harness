import 'issue.dart';

/// A read-your-writes overlay over GitHub's eventually-consistent issue list.
///
/// During a run the harness is the only writer of these labels and states, so
/// its own record beats `gh issue list`, whose index lags a write by seconds.
/// That lag once let a just-closed sub read back as still-open and skip its PR
/// (`open_subs=1 [#self]`). The overlay reconciles every list read against the
/// writes the harness has *confirmed* (the caller checks the `gh` exit code, so a
/// close that did not take never masks an open issue). Per-process only; across
/// runs GitHub has converged, so it never hides a human's out-of-band reopen.
class IssueStateOverlay {
  final Map<int, Issue> _seen = {};
  final Set<int> _closed = {};
  final Map<int, Set<String>> _labels = {};

  /// Caches issues from a raw list read so a later [reconcile] can reconstruct one
  /// it must surface (relabeled into a queue the index has not caught up to yet).
  void observe(Iterable<Issue> issues) {
    for (final issue in issues) {
      _seen[issue.number] = issue;
    }
  }

  void recordClosed(int number) {
    _closed.add(number);
    _labels.remove(number);
  }

  void recordDroppedAgentLabel(int number) =>
      _labels[number] = _currentLabels(number)..remove('ready-for-agent');

  void recordRelabeledForHuman(int number) =>
      _labels[number] = _currentLabels(number)
        ..remove('ready-for-agent')
        ..add('ready-for-human');

  Set<String> _currentLabels(int number) => {
    ..._labels[number] ?? _seen[number]?.labels ?? const <String>[],
  };

  /// [raw] (a `gh issue list --label [label] --state [state]` result) reconciled
  /// against confirmed local writes: a confirmed-closed issue drops out of an
  /// `open` read, one whose confirmed labels no longer carry [label] drops out,
  /// and one confirmed to now carry [label] is surfaced even if the index lags.
  /// With nothing recorded, [raw] is returned unchanged.
  List<Issue> reconcile(
    List<Issue> raw, {
    required String label,
    required String state,
  }) {
    final isOpenQuery = state == 'open';
    final result = <int, Issue>{for (final issue in raw) issue.number: issue};

    result.removeWhere((number, _) {
      if (isOpenQuery && _closed.contains(number)) return true;
      final labels = _labels[number];
      return labels != null && !labels.contains(label);
    });

    if (isOpenQuery) {
      for (final entry in _labels.entries) {
        final number = entry.key;
        if (result.containsKey(number) ||
            _closed.contains(number) ||
            !entry.value.contains(label)) {
          continue;
        }
        final seen = _seen[number];
        if (seen != null) {
          result[number] = Issue(
            number: number,
            title: seen.title,
            body: seen.body,
            labels: entry.value.toList(),
            url: seen.url,
          );
        }
      }
    }

    return result.values.toList();
  }
}
