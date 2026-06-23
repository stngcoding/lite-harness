import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('CallRecord', () {
    test('round-trips every field through a JSON line', () {
      const record = CallRecord(
        ts: '2026-06-23T08:00:00.000',
        phase: CallPhase.implement,
        issue: 12,
        prd: 10,
        model: 'sonnet',
        attempt: 2,
        costUsd: 0.4231,
        numTurns: 7,
        durationMs: 53210,
        ctxFreePct: 41.5,
        outcome: 'success',
        denials: 3,
      );
      final parsed = CallRecord.parse(record.toJsonLine());
      expect(parsed.ts, record.ts);
      expect(parsed.phase, CallPhase.implement);
      expect(parsed.issue, 12);
      expect(parsed.prd, 10);
      expect(parsed.model, 'sonnet');
      expect(parsed.attempt, 2);
      expect(parsed.costUsd, closeTo(0.4231, 1e-9));
      expect(parsed.numTurns, 7);
      expect(parsed.durationMs, 53210);
      expect(parsed.ctxFreePct, closeTo(41.5, 1e-9));
      expect(parsed.outcome, 'success');
      expect(parsed.denials, 3);
    });

    test('omits null optionals and a zero denial count', () {
      const record = CallRecord(
        ts: 't',
        phase: CallPhase.classify,
        costUsd: 0.01,
        numTurns: 1,
        durationMs: 900,
      );
      final line = record.toJsonLine();
      expect(line, isNot(contains('issue')));
      expect(line, isNot(contains('prd')));
      expect(line, isNot(contains('model')));
      expect(line, isNot(contains('attempt')));
      expect(line, isNot(contains('ctxFreePct')));
      expect(line, isNot(contains('outcome')));
      expect(line, isNot(contains('denials')));

      final parsed = CallRecord.parse(line);
      expect(parsed.issue, isNull);
      expect(parsed.prd, isNull);
      expect(parsed.model, isNull);
      expect(parsed.attempt, isNull);
      expect(parsed.ctxFreePct, isNull);
      expect(parsed.outcome, isNull);
      expect(parsed.denials, 0);
    });

    test('keeps the phase label stable on the wire', () {
      expect(
        const CallRecord(
          ts: 't',
          phase: CallPhase.prReview,
          costUsd: 1,
          numTurns: 1,
          durationMs: 1,
        ).toJsonLine(),
        contains('"phase":"pr-review"'),
      );
    });
  });

  group('CallLog', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ralph-calls-test');
      path = '${dir.path}/nested/calls.jsonl';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('appends across calls and creates the parent dir', () {
      CallLog(path)
        ..append(
          const CallRecord(
            ts: 't1',
            phase: CallPhase.classify,
            issue: 1,
            costUsd: 0.02,
            numTurns: 1,
            durationMs: 500,
          ),
        )
        ..append(
          const CallRecord(
            ts: 't2',
            phase: CallPhase.implement,
            issue: 1,
            model: 'opus',
            attempt: 1,
            costUsd: 0.5,
            numTurns: 9,
            durationMs: 60000,
          ),
        );

      final all = CallLog(path).readAll();
      expect(all, hasLength(2));
      expect(all[0].phase, CallPhase.classify);
      expect(all[1].model, 'opus');
    });

    test('readAll on a missing file returns empty', () {
      expect(CallLog(path).readAll(), isEmpty);
    });
  });

  group('summarizeCalls', () {
    CallRecord rec(
      CallPhase phase,
      double cost, {
      String? model,
      int turns = 1,
      int durationMs = 1000,
      int denials = 0,
    }) => CallRecord(
      ts: 't',
      phase: phase,
      model: model,
      costUsd: cost,
      numTurns: turns,
      durationMs: durationMs,
      denials: denials,
    );

    test('is empty for no records', () {
      expect(summarizeCalls(const []).isEmpty, isTrue);
    });

    test('splits spend by phase and by model, most-expensive first', () {
      final report = summarizeCalls([
        rec(CallPhase.classify, 0.02),
        rec(CallPhase.implement, 0.30, model: 'sonnet'),
        rec(CallPhase.implement, 0.50, model: 'opus'),
        rec(CallPhase.prReview, 0.10),
      ]);

      expect(report.totalCalls, 4);
      expect(report.totalCostUsd, closeTo(0.92, 1e-9));

      expect(report.phaseStats.first.phase, CallPhase.implement);
      expect(report.phaseStats.first.costUsd, closeTo(0.80, 1e-9));
      expect(report.phaseStats.first.calls, 2);

      // Only model-tagged calls land in the by-model split; classify/prReview
      // carry no model and are left out.
      final models = [for (final s in report.modelStats) s.model];
      expect(models, ['opus', 'sonnet']);
    });

    test(
      'estimates the all-Opus implement counterfactual from cost factors',
      () {
        final report = summarizeCalls([
          rec(CallPhase.implement, 0.30, model: 'sonnet'),
          rec(CallPhase.implement, 0.50, model: 'opus'),
        ]);

        // Actual = 0.30 + 0.50. All-Opus grosses the Sonnet call up by its 0.6
        // factor: 0.30 / 0.6 = 0.50, plus the Opus call unchanged = 1.00.
        expect(report.implementActualUsd, closeTo(0.80, 1e-9));
        expect(report.implementAllOpusUsd, closeTo(1.00, 1e-9));
        expect(report.tieringSavingUsd, closeTo(0.20, 1e-9));
        expect(report.render(), contains('Implement tiering'));
      },
    );

    test(
      'skips unpriced or model-less implement calls in the counterfactual',
      () {
        final report = summarizeCalls([
          rec(CallPhase.implement, 0.40),
          rec(CallPhase.implement, 0.40, model: 'mystery-model'),
        ]);
        expect(report.implementActualUsd, 0);
        expect(report.implementAllOpusUsd, 0);
        expect(report.render(), isNot(contains('Implement tiering')));
      },
    );

    test('totals turns/duration/denials and warns on a denial', () {
      final report = summarizeCalls([
        rec(
          CallPhase.implement,
          0.10,
          model: 'opus',
          turns: 4,
          durationMs: 2000,
        ),
        rec(CallPhase.ciFix, 0.05, model: 'opus', turns: 2, denials: 1),
      ]);
      expect(report.totalTurns, 6);
      expect(report.totalDurationMs, 3000);
      expect(report.totalDenials, 1);
      expect(report.render(), contains('permission denial'));
    });
  });
}
