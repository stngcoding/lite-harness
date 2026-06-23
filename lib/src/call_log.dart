import 'dart:convert';
import 'dart:io';

/// Persistent path for the per-call cost ledger. Lives in the target repo
/// beside `.dartralph/traces.jsonl` (not under `/tmp` like the per-run event
/// log) so the spend record survives across runs and is analyzable after the
/// fact — the durable answer to "which phase/model burned the most on this
/// PRD". Excluded from commits/drift via `GitOps.artifactExcludes`.
const callLogPath = '.dartralph/calls.jsonl';

/// Which step of the loop a `claude` call belongs to. This is the dimension the
/// cost report groups by — the original "$20 per PRD, where does it go?"
/// question is answered by the per-phase spend split. `classify` runs the
/// intake agent; `prReview` runs the diff-verifier; the rest run the
/// implementer model.
enum CallPhase {
  classify('classify'),
  implement('implement'),
  prReview('pr-review'),
  reviewFix('review-fix'),
  ciFix('ci-fix');

  const CallPhase(this.label);

  final String label;
}

/// Each model's billed cost relative to Opus (= 1.0), derived from the public
/// per-MTok pricing and assumed proportional per call: Sonnet bills 0.6× and
/// Haiku 0.2× an Opus call of the same token shape, Fable 2.0×. This is what
/// lets [summarizeCalls] estimate the all-Opus counterfactual — what the
/// implement spend *would* have been with no lane tiering — so the savings the
/// `model_ladder` buys are visible, not guessed.
const modelCostFactor = <String, double>{
  'haiku': 0.2,
  'sonnet': 0.6,
  'opus': 1.0,
  'fable': 2.0,
};

/// One `claude` call's terminal telemetry: which phase/issue it served, the
/// model it ran on, and the cost/turns/duration the `result` event reported.
/// Appended once per completed call — the structured form of the
/// `└ N turns · $X · Ys` line the human transcript prints and then forgets.
class CallRecord {
  const CallRecord({
    required this.ts,
    required this.phase,
    required this.costUsd,
    required this.numTurns,
    required this.durationMs,
    this.issue,
    this.prd,
    this.model,
    this.attempt,
    this.ctxFreePct,
    this.outcome,
    this.denials = 0,
  });

  factory CallRecord.parse(String line) {
    final json = jsonDecode(line) as Map<String, dynamic>;
    return CallRecord(
      ts: json['ts'] as String,
      phase: CallPhase.values.firstWhere((p) => p.label == json['phase']),
      issue: json['issue'] as int?,
      prd: json['prd'] as int?,
      model: json['model'] as String?,
      attempt: json['attempt'] as int?,
      costUsd: (json['costUsd'] as num).toDouble(),
      numTurns: json['numTurns'] as int,
      durationMs: json['durationMs'] as int,
      ctxFreePct: (json['ctxFreePct'] as num?)?.toDouble(),
      outcome: json['outcome'] as String?,
      denials: json['denials'] as int? ?? 0,
    );
  }

  final String ts;
  final CallPhase phase;

  /// The sub-issue this call served (null for a PRD-level review/fix call).
  final int? issue;

  /// The PRD parent for grouping, or null for a PRD-of-one.
  final int? prd;

  /// The model the call ran on (`sonnet`, `opus`, …), or null for an
  /// agent-pinned call whose model the harness does not pass (`classify`,
  /// `prReview`). Null calls are left out of the by-model split and the
  /// all-Opus counterfactual.
  final String? model;

  /// The 1-based implement attempt this call was, or null for non-implement
  /// phases — so an escalation (a retry that climbed a model rung) is visible.
  final int? attempt;

  final double costUsd;
  final int numTurns;
  final int durationMs;

  /// Context-window headroom left at the call's peak, as a percentage — a low
  /// value flags a call that ran close to truncating its own working memory.
  final double? ctxFreePct;

  /// The `result` event subtype (`success`, `error_max_turns`,
  /// `error_during_execution`), or null when the process died before emitting
  /// one. The high-signal field for debugging which calls failed.
  final String? outcome;

  /// Tool calls the permission layer blocked — non-zero means the agent
  /// silently failed to do something.
  final int denials;

  String toJsonLine() => jsonEncode({
    'ts': ts,
    'phase': phase.label,
    if (issue != null) 'issue': issue,
    if (prd != null) 'prd': prd,
    if (model != null) 'model': model,
    if (attempt != null) 'attempt': attempt,
    'costUsd': costUsd,
    'numTurns': numTurns,
    'durationMs': durationMs,
    if (ctxFreePct != null) 'ctxFreePct': ctxFreePct,
    if (outcome != null) 'outcome': outcome,
    if (denials != 0) 'denials': denials,
  });
}

/// Append-only JSONL ledger for [CallRecord]s. Synchronous append (like
/// `TraceStore`/`EventLog`) so a call's spend survives a crash mid-run; creates
/// `.dartralph/` on first write. Never truncates — the point is a durable spend
/// history a later run (or a human) can analyze without re-scraping stdout.
class CallLog {
  CallLog([this.path = callLogPath]);

  final String path;

  void append(CallRecord record) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${record.toJsonLine()}\n', mode: FileMode.append);
  }

  List<CallRecord> readAll() {
    final file = File(path);
    if (!file.existsSync()) return const [];
    return [
      for (final line in file.readAsLinesSync())
        if (line.trim().isNotEmpty) CallRecord.parse(line),
    ];
  }
}

/// A phase's spend tally for the report.
class PhaseStat {
  const PhaseStat({
    required this.phase,
    required this.calls,
    required this.costUsd,
  });

  final CallPhase phase;
  final int calls;
  final double costUsd;
}

/// A model's spend tally for the report (model-tagged calls only).
class ModelStat {
  const ModelStat({
    required this.model,
    required this.calls,
    required this.costUsd,
  });

  final String model;
  final int calls;
  final double costUsd;
}

/// The cost aggregate the harness prints at the end of a run: the spend split by
/// phase and by model, plus the implement lane-tiering counterfactual (what the
/// implement spend would have cost with every slice on Opus).
class CostReport {
  const CostReport({
    required this.totalCalls,
    required this.totalCostUsd,
    required this.totalTurns,
    required this.totalDurationMs,
    required this.totalDenials,
    required this.phaseStats,
    required this.modelStats,
    required this.implementActualUsd,
    required this.implementAllOpusUsd,
  });

  final int totalCalls;
  final double totalCostUsd;
  final int totalTurns;
  final int totalDurationMs;
  final int totalDenials;

  /// Per-phase spend, most-expensive phase first.
  final List<PhaseStat> phaseStats;

  /// Per-model spend (model-tagged calls only), most-expensive first.
  final List<ModelStat> modelStats;

  /// Actual implement spend, and what it would have been with every implement
  /// call on Opus — the gap is the lane-tiering saving (an estimate: it assumes
  /// each call's token shape is model-independent).
  final double implementActualUsd;
  final double implementAllOpusUsd;

  bool get isEmpty => totalCalls == 0;

  double get tieringSavingUsd => implementAllOpusUsd - implementActualUsd;

  String _usd(double v) => '\$${v.toStringAsFixed(4)}';

  String render() {
    final b = StringBuffer()
      ..writeln('── Cost report (this run) ──')
      ..writeln(
        'Total: ${_usd(totalCostUsd)} · $totalCalls calls · '
        '$totalTurns turns · ${(totalDurationMs / 1000).toStringAsFixed(1)}s',
      );

    final phaseWidth = phaseStats.isEmpty
        ? 0
        : phaseStats
              .map((s) => s.phase.label.length)
              .reduce((a, c) => a > c ? a : c);
    b.writeln('By phase (cost desc):');
    for (final s in phaseStats) {
      b.writeln(
        '  ${s.phase.label.padRight(phaseWidth)}  ${_usd(s.costUsd)}  '
        '(${s.calls} call${s.calls == 1 ? '' : 's'})',
      );
    }

    if (modelStats.isNotEmpty) {
      final modelWidth = modelStats
          .map((s) => s.model.length)
          .reduce((a, c) => a > c ? a : c);
      b.writeln('By model (cost desc):');
      for (final s in modelStats) {
        b.writeln(
          '  ${s.model.padRight(modelWidth)}  ${_usd(s.costUsd)}  '
          '(${s.calls} call${s.calls == 1 ? '' : 's'})',
        );
      }
    }

    if (implementAllOpusUsd > 0) {
      final pct = (tieringSavingUsd / implementAllOpusUsd * 100).round();
      b.writeln(
        'Implement tiering: ${_usd(implementActualUsd)} actual vs '
        '~${_usd(implementAllOpusUsd)} all-Opus → saved '
        '~${_usd(tieringSavingUsd)} ($pct%) [estimate]',
      );
    }

    if (totalDenials > 0) {
      b.writeln(
        '⚠ $totalDenials permission denial(s) across the run — an agent may '
        'have silently failed to do something.',
      );
    }

    return b.toString().trimRight();
  }
}

/// Aggregates [records] into a [CostReport]: totals, the per-phase and per-model
/// spend splits (most-expensive first), and the implement lane-tiering
/// counterfactual. The all-Opus estimate sums each implement call's
/// `cost / modelCostFactor[model]` (Opus's factor is 1.0, so an Opus call is
/// unchanged; a Sonnet call grosses up to its Opus-equivalent), skipping calls
/// whose model is unknown or unpriced.
CostReport summarizeCalls(List<CallRecord> records) {
  final phaseCost = <CallPhase, double>{};
  final phaseCalls = <CallPhase, int>{};
  final modelCost = <String, double>{};
  final modelCalls = <String, int>{};
  var totalCost = 0.0;
  var totalTurns = 0;
  var totalDuration = 0;
  var totalDenials = 0;
  var implActual = 0.0;
  var implAllOpus = 0.0;

  for (final r in records) {
    totalCost += r.costUsd;
    totalTurns += r.numTurns;
    totalDuration += r.durationMs;
    totalDenials += r.denials;
    phaseCost[r.phase] = (phaseCost[r.phase] ?? 0) + r.costUsd;
    phaseCalls[r.phase] = (phaseCalls[r.phase] ?? 0) + 1;

    final model = r.model;
    if (model != null) {
      modelCost[model] = (modelCost[model] ?? 0) + r.costUsd;
      modelCalls[model] = (modelCalls[model] ?? 0) + 1;
    }

    if (r.phase == CallPhase.implement) {
      final factor = model == null ? null : modelCostFactor[model];
      if (factor != null && factor > 0) {
        implActual += r.costUsd;
        implAllOpus += r.costUsd / factor;
      }
    }
  }

  final phaseStats = [
    for (final entry in phaseCost.entries)
      PhaseStat(
        phase: entry.key,
        calls: phaseCalls[entry.key]!,
        costUsd: entry.value,
      ),
  ]..sort((a, b) => b.costUsd.compareTo(a.costUsd));

  final modelStats = [
    for (final entry in modelCost.entries)
      ModelStat(
        model: entry.key,
        calls: modelCalls[entry.key]!,
        costUsd: entry.value,
      ),
  ]..sort((a, b) => b.costUsd.compareTo(a.costUsd));

  return CostReport(
    totalCalls: records.length,
    totalCostUsd: totalCost,
    totalTurns: totalTurns,
    totalDurationMs: totalDuration,
    totalDenials: totalDenials,
    phaseStats: phaseStats,
    modelStats: modelStats,
    implementActualUsd: implActual,
    implementAllOpusUsd: implAllOpus,
  );
}
