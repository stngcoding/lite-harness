import 'dart:convert';
import 'dart:io';

import 'verdict.dart';

/// The cross-run trace log path. Unlike the per-run [EventLog] (truncated under
/// `/tmp`), it lives in the target repo so friction accumulates across runs —
/// what lets the propose step spot a multi-run pattern. Excluded from
/// commits/drift via `GitOps.artifactExcludes`.
const traceStorePath = '.dartralph/traces.jsonl';

/// A named reason a slice or PR did not sail through. The propose step counts
/// these: one is noise, the same one recurring is a harness problem to surface.
enum FrictionKind {
  gateAnalyzeFail,
  gateTestFail,
  retryExhausted,
  noChanges,
  reviewerReject,
  commitFail,
  apiError,
  classifyFail,
  contextStarved,
  secretLeak,
  ciFail,
}

/// One issue's (or PR's) outcome for a run: its risk lane, how many attempts it
/// took, and which frictions it hit. Appended once per terminal outcome.
class TraceRecord {
  const TraceRecord({
    required this.ts,
    required this.lane,
    required this.outcome,
    required this.attempts,
    required this.frictions,
    this.issue,
    this.prd,
    this.detail,
    this.signature,
    this.model,
  });

  factory TraceRecord.parse(String line) {
    final json = jsonDecode(line) as Map<String, dynamic>;
    return TraceRecord(
      ts: json['ts'] as String,
      issue: json['issue'] as int?,
      prd: json['prd'] as int?,
      lane: RiskLane.values.firstWhere((l) => l.label == json['lane']),
      outcome: json['outcome'] as String,
      attempts: json['attempts'] as int,
      frictions: [
        for (final f in (json['frictions'] as List? ?? []))
          FrictionKind.values.byName(f as String),
      ],
      detail: json['detail'] as String?,
      signature: json['signature'] as String?,
      model: json['model'] as String?,
    );
  }

  final String ts;
  final int? issue;
  final int? prd;
  final RiskLane lane;

  /// `pass`, `fail`, or `draft`.
  final String outcome;
  final int attempts;
  final List<FrictionKind> frictions;
  final String? detail;

  /// One-line error signature for a non-pass outcome (the first failing log
  /// line), or null on a clean pass — the bit [recurringSignatures] aggregates
  /// into the implementer's pitfalls digest.
  final String? signature;

  /// The model the last implement attempt ran on, or null for a trace written
  /// before model tiering — makes lane→model tiering and escalation visible.
  final String? model;

  String toJsonLine() => jsonEncode({
    'ts': ts,
    if (issue != null) 'issue': issue,
    if (prd != null) 'prd': prd,
    'lane': lane.label,
    'outcome': outcome,
    'attempts': attempts,
    'frictions': [for (final f in frictions) f.name],
    if (detail != null) 'detail': detail,
    if (signature != null) 'signature': signature,
    if (model != null) 'model': model,
  });
}

/// Append-only JSONL store for [TraceRecord]s. Synchronous append so a trace
/// survives a crash mid-run; never truncates — the point is cross-run history.
class TraceStore {
  TraceStore([this.path = traceStorePath]);

  final String path;

  void append(TraceRecord record) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${record.toJsonLine()}\n', mode: FileMode.append);
  }

  List<TraceRecord> readAll() {
    final file = File(path);
    if (!file.existsSync()) return const [];
    return [
      for (final line in file.readAsLinesSync())
        if (line.trim().isNotEmpty) TraceRecord.parse(line),
    ];
  }
}

/// Per-lane outcome tally for the report.
class LaneStat {
  const LaneStat({
    required this.lane,
    required this.total,
    required this.failed,
  });

  final RiskLane lane;
  final int total;

  /// Records in this lane whose outcome was not `pass`.
  final int failed;
}

/// A rule-based, evidence-backed improvement suggestion: a friction that
/// recurred enough to be worth acting on. Advisory only — never auto-applied.
class Proposal {
  const Proposal({
    required this.kind,
    required this.count,
    required this.suggestion,
  });

  final FrictionKind kind;
  final int count;
  final String suggestion;
}

/// The aggregate the harness prints at the end of a run.
class FrictionReport {
  const FrictionReport({
    required this.totalTraces,
    required this.frictionCounts,
    required this.laneStats,
    required this.proposals,
  });

  final int totalTraces;
  final Map<FrictionKind, int> frictionCounts;
  final List<LaneStat> laneStats;
  final List<Proposal> proposals;

  bool get isEmpty => totalTraces == 0;

  String render() {
    final b = StringBuffer()
      ..writeln('── Friction report ($totalTraces traces across runs) ──');
    if (laneStats.isNotEmpty) {
      b.writeln('Lanes (not-passed / total):');
      for (final s in laneStats) {
        b.writeln('  ${s.lane.label}: ${s.failed}/${s.total}');
      }
    }
    if (proposals.isEmpty) {
      b.writeln('No repeated friction (≥2). Nothing to propose.');
    } else {
      b.writeln('Repeated friction → proposals:');
      for (final p in proposals) {
        b.writeln('  [${p.count}×] ${p.kind.name}: ${p.suggestion}');
      }
    }
    return b.toString().trimRight();
  }
}

/// Canned suggestion per friction kind. Deterministic by design: the propose
/// step surfaces evidence and a fixed next-step, never a free-form invention.
const _suggestions = <FrictionKind, String>{
  FrictionKind.gateAnalyzeFail:
      'Repeated analyze failures — surface the project lint rules more '
      'prominently in the implementer prompt.',
  FrictionKind.gateTestFail:
      'Slices keep failing the scoped test gate — strengthen the '
      'test-coverage expectation for normal/high-risk lanes.',
  FrictionKind.retryExhausted:
      'Issues exhausting every attempt — split them smaller, raise '
      'maxAttempts, or route to a human sooner.',
  FrictionKind.noChanges:
      'Implementer repeatedly produced no changes — issue bodies may be '
      'under-specified; consider a needs-info triage step.',
  FrictionKind.reviewerReject:
      'PRs repeatedly rejected by the reviewer — recurring integration/'
      'contract gaps; strengthen the high-risk reviewer bar or coherence '
      'context.',
  FrictionKind.commitFail:
      'Commits failing — check artifactExcludes and drift handling.',
  FrictionKind.apiError:
      'Repeated API errors — transient infra; consider tuning the retry '
      'backoff.',
  FrictionKind.classifyFail:
      'Intake classification kept failing to emit a lane — check the intake '
      'agent and prompt.',
  FrictionKind.contextStarved:
      'Slices ran the context window low before failing — they are likely too '
      'large; split them into smaller sub-issues.',
  FrictionKind.secretLeak:
      'Slices keep adding apparent secrets — tighten the implementer prompt to '
      'use env/secret storage and never hardcode credentials.',
  FrictionKind.ciFail:
      'PRs keep failing remote CI after passing local gates — the local gates '
      'diverge from CI (a step, OS, or check CI runs that the harness does '
      'not); align the local gates with the CI workflow.',
};

/// Aggregates [records] into a [FrictionReport]: friction counts, per-lane
/// not-passed tallies, and a proposal for every friction seen at least twice
/// (most-frequent first). A one-off is left out — only a pattern is actionable.
FrictionReport summarize(List<TraceRecord> records) {
  final frictionCounts = <FrictionKind, int>{};
  final byLane = <RiskLane, List<TraceRecord>>{};
  for (final r in records) {
    byLane.putIfAbsent(r.lane, () => []).add(r);
    for (final f in r.frictions) {
      frictionCounts[f] = (frictionCounts[f] ?? 0) + 1;
    }
  }
  final laneStats = [
    for (final lane in RiskLane.values)
      if (byLane[lane] case final group?)
        LaneStat(
          lane: lane,
          total: group.length,
          failed: group.where((r) => r.outcome != 'pass').length,
        ),
  ];
  final proposals = [
    for (final entry in frictionCounts.entries)
      if (entry.value >= 2)
        Proposal(
          kind: entry.key,
          count: entry.value,
          suggestion: _suggestions[entry.key] ?? 'Recurring friction.',
        ),
  ]..sort((a, b) => b.count.compareTo(a.count));
  return FrictionReport(
    totalTraces: records.length,
    frictionCounts: frictionCounts,
    laneStats: laneStats,
    proposals: proposals,
  );
}

String _clip(String s) => s.length <= 120 ? s : '${s.substring(0, 117)}...';

/// Lines that look like the actual failure rather than progress/noise, in
/// priority order: a `flutter analyze` error row, a test matcher's `Expected:`,
/// the compact reporter's `[E]` failure marker, or a thrown error/exception.
final _errorMarkers = [
  RegExp(r'error\s+•'),
  RegExp(r'^Expected:'),
  RegExp(r'\[E\]$'),
  RegExp(r'(?:Exception|Error):'),
  RegExp(r'^FAILED\b|Failed to'),
];

/// Extracts a one-line error signature from a gate [log]: the first line
/// matching an [_errorMarkers] pattern, else the first non-empty line. Clipped
/// to 120 chars so a trace stays a single high-signal line. Null for empty input.
String? errorSignature(String log) {
  String? firstNonEmpty;
  for (final raw in log.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    firstNonEmpty ??= line;
    for (final marker in _errorMarkers) {
      if (marker.hasMatch(line)) return _clip(line);
    }
  }
  return firstNonEmpty == null ? null : _clip(firstNonEmpty);
}

/// A volatility-stripped fingerprint so the same *class* of failure recurs across
/// different files/lines (path tokens dropped, digits → `#`, whitespace
/// collapsed). The discriminating parts — a rule name, a matcher message —
/// survive and key the recurrence count.
String _fingerprint(String signature) => signature
    .toLowerCase()
    .replaceAll(RegExp(r'\S*\.dart\S*'), '')
    .replaceAll(RegExp(r'\d+'), '#')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Error signatures seen at least [minCount] times within the most recent
/// [window] traces, most-frequent first, capped at [top] — the source of the
/// implementer's "known pitfalls" digest. Each returned string is the most recent
/// raw signature for its fingerprint (a concrete example).
List<String> recurringSignatures(
  List<TraceRecord> records, {
  int window = 50,
  int minCount = 2,
  int top = 3,
}) {
  final recent = records.length > window
      ? records.sublist(records.length - window)
      : records;
  final counts = <String, int>{};
  final representative = <String, String>{};
  for (final r in recent) {
    final sig = r.signature;
    if (sig == null || sig.isEmpty) continue;
    final key = _fingerprint(sig);
    counts[key] = (counts[key] ?? 0) + 1;
    representative[key] = sig;
  }
  final ranked = counts.entries.where((e) => e.value >= minCount).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [for (final e in ranked.take(top)) representative[e.key]!];
}
