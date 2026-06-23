import 'dart:convert';

/// The aggregate verdict of a PR's remote CI checks, distilled from GitHub's
/// `statusCheckRollup`. Precedence is `pending > failing > passing > none`: the
/// final phase waits while anything is still running ([CiState.pending]) so a
/// fix never fires against a half-finished run, then acts on the settled state.
enum CiState {
  /// No check runs or commit statuses are attached to the head commit at all —
  /// the repo has no CI for this branch (or none has registered yet).
  none,

  /// At least one check is still queued or in progress; the verdict is not in.
  pending,

  /// Every check has concluded and none failed.
  passing,

  /// All checks have concluded and at least one failed (and nothing is left
  /// pending). [CiStatus.failedRunIds] names the Actions runs to pull logs from.
  failing,
}

/// A point-in-time read of a PR's CI: the aggregate [state], whether GitHub
/// considers the branch [mergeable] against its base (null = unknown), and the
/// distinct Actions run ids behind any failing check (for `--log-failed`).
class CiStatus {
  const CiStatus({
    required this.state,
    this.mergeable,
    this.failedRunIds = const [],
  });

  final CiState state;

  /// `true` mergeable, `false` conflicting, `null` when GitHub has not computed
  /// it yet. A passing build that is not mergeable still must not be marked
  /// ready — base moved under the branch.
  final bool? mergeable;

  /// De-duplicated GitHub Actions run ids behind the failing checks, in first-
  /// seen order. Empty unless [state] is [CiState.failing].
  final List<int> failedRunIds;
}

/// Parses the JSON from `gh pr view <ref> --json statusCheckRollup,mergeable`
/// into a [CiStatus]. Tolerant by construction: malformed JSON, a missing
/// rollup, or unknown entry shapes degrade to [CiState.none] rather than throw,
/// so a parse hiccup never fails a PR — the caller just sees "no CI" and falls
/// back to the local-gate verdict.
CiStatus parseCiStatus(String ghJson) {
  final Map<String, dynamic> root;
  try {
    final decoded = jsonDecode(ghJson);
    if (decoded is! Map<String, dynamic>) {
      return const CiStatus(state: CiState.none);
    }
    root = decoded;
  } on FormatException {
    return const CiStatus(state: CiState.none);
  }

  final mergeable = switch (root['mergeable']) {
    'MERGEABLE' => true,
    'CONFLICTING' => false,
    _ => null,
  };

  final rollup = root['statusCheckRollup'];
  if (rollup is! List || rollup.isEmpty) {
    return CiStatus(state: CiState.none, mergeable: mergeable);
  }

  var anyPending = false;
  var anyFailing = false;
  final failedRunIds = <int>[];
  void addRun(int? id) {
    if (id != null && !failedRunIds.contains(id)) failedRunIds.add(id);
  }

  for (final raw in rollup) {
    if (raw is! Map<String, dynamic>) continue;
    switch (raw['__typename']) {
      // GitHub Actions / app check runs.
      case 'CheckRun':
        if (raw['status'] != 'COMPLETED') {
          anyPending = true;
          break;
        }
        switch (raw['conclusion']) {
          case 'SUCCESS':
          case 'SKIPPED':
          case 'NEUTRAL':
            break;
          case null:
            anyPending = true;
          default:
            anyFailing = true;
            addRun(runIdFromDetailsUrl(raw['detailsUrl'] as String?));
        }
      // Legacy commit statuses (e.g. external CI posting via the Status API).
      case 'StatusContext':
        switch (raw['state']) {
          case 'SUCCESS':
            break;
          case 'PENDING':
          case 'EXPECTED':
            anyPending = true;
          default:
            anyFailing = true;
            addRun(runIdFromDetailsUrl(raw['targetUrl'] as String?));
        }
    }
  }

  final state = anyPending
      ? CiState.pending
      : anyFailing
      ? CiState.failing
      : CiState.passing;
  return CiStatus(
    state: state,
    mergeable: mergeable,
    failedRunIds: failedRunIds,
  );
}

final _runIdInUrl = RegExp(r'/actions/runs/(\d+)');

/// Pulls the Actions run id out of a check's `detailsUrl`/`targetUrl`, e.g.
/// `https://github.com/o/r/actions/runs/123456/job/789` → `123456`. Returns
/// null for a URL that is not an Actions-run link (an external CI's own URL),
/// in which case there are no `gh run` logs to fetch.
int? runIdFromDetailsUrl(String? url) {
  if (url == null) return null;
  final match = _runIdInUrl.firstMatch(url);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// The CI poll cadence, a pure function of how long we have been watching:
/// every 30s for the first 5 minutes, every 60s through 15 minutes, every 120s
/// after that. Mirrors the no-mistakes schedule — tight while CI is most likely
/// to flip, then backing off so a slow build is not hammered.
Duration ciPollInterval(Duration elapsed) {
  if (elapsed < const Duration(minutes: 5)) return const Duration(seconds: 30);
  if (elapsed < const Duration(minutes: 15)) return const Duration(seconds: 60);
  return const Duration(seconds: 120);
}
