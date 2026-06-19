import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('TraceRecord', () {
    test('round-trips through a JSON line', () {
      const record = TraceRecord(
        ts: '2026-06-18T08:00:00.000',
        issue: 12,
        prd: 10,
        lane: RiskLane.highRisk,
        outcome: 'fail',
        attempts: 3,
        frictions: [FrictionKind.gateTestFail, FrictionKind.retryExhausted],
        detail: 'analyze=1 test=0',
      );
      final parsed = TraceRecord.parse(record.toJsonLine());
      expect(parsed.ts, record.ts);
      expect(parsed.issue, 12);
      expect(parsed.prd, 10);
      expect(parsed.lane, RiskLane.highRisk);
      expect(parsed.outcome, 'fail');
      expect(parsed.attempts, 3);
      expect(parsed.frictions, record.frictions);
      expect(parsed.detail, 'analyze=1 test=0');
    });

    test('omits null issue/prd/detail and parses them back as null', () {
      const record = TraceRecord(
        ts: '2026-06-18T08:00:00.000',
        lane: RiskLane.tiny,
        outcome: 'pass',
        attempts: 1,
        frictions: [],
      );
      final line = record.toJsonLine();
      expect(line, isNot(contains('issue')));
      expect(line, isNot(contains('detail')));
      final parsed = TraceRecord.parse(line);
      expect(parsed.issue, isNull);
      expect(parsed.prd, isNull);
      expect(parsed.detail, isNull);
      expect(parsed.frictions, isEmpty);
    });
  });

  group('TraceStore', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ralph-traces-test');
      path = '${dir.path}/nested/traces.jsonl';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('appends across calls and creates the parent dir', () {
      final store = TraceStore(path)
        ..append(
          const TraceRecord(
            ts: 't1',
            issue: 1,
            lane: RiskLane.tiny,
            outcome: 'pass',
            attempts: 1,
            frictions: [],
          ),
        )
        ..append(
          const TraceRecord(
            ts: 't2',
            issue: 2,
            lane: RiskLane.normal,
            outcome: 'fail',
            attempts: 3,
            frictions: [FrictionKind.gateTestFail],
          ),
        );

      final all = store.readAll();
      expect(all, hasLength(2));
      expect(all[0].issue, 1);
      expect(all[1].frictions, [FrictionKind.gateTestFail]);
    });

    test('readAll on a missing file returns empty', () {
      expect(TraceStore(path).readAll(), isEmpty);
    });
  });

  group('summarize', () {
    TraceRecord rec(
      RiskLane lane,
      String outcome,
      List<FrictionKind> frictions,
    ) => TraceRecord(
      ts: 't',
      lane: lane,
      outcome: outcome,
      attempts: 1,
      frictions: frictions,
    );

    test('counts frictions and per-lane not-passed tallies', () {
      final report = summarize([
        rec(RiskLane.tiny, 'pass', []),
        rec(RiskLane.normal, 'fail', [FrictionKind.gateTestFail]),
        rec(RiskLane.normal, 'pass', []),
        rec(RiskLane.highRisk, 'draft', [FrictionKind.reviewerReject]),
      ]);
      expect(report.totalTraces, 4);
      expect(report.frictionCounts[FrictionKind.gateTestFail], 1);

      final normal = report.laneStats.firstWhere(
        (s) => s.lane == RiskLane.normal,
      );
      expect(normal.total, 2);
      expect(normal.failed, 1);

      final high = report.laneStats.firstWhere(
        (s) => s.lane == RiskLane.highRisk,
      );
      expect(high.failed, 1); // 'draft' is not 'pass'
    });

    test('proposes only frictions that recur at least twice, most-frequent '
        'first', () {
      final report = summarize([
        rec(RiskLane.normal, 'fail', [FrictionKind.gateTestFail]),
        rec(RiskLane.normal, 'fail', [
          FrictionKind.gateTestFail,
          FrictionKind.retryExhausted,
        ]),
        rec(RiskLane.normal, 'fail', [
          FrictionKind.gateTestFail,
          FrictionKind.retryExhausted,
        ]),
        rec(RiskLane.tiny, 'fail', [FrictionKind.noChanges]),
      ]);
      final kinds = [for (final p in report.proposals) p.kind];
      // gateTestFail ×3, retryExhausted ×2 surface; noChanges ×1 does not.
      expect(kinds, [FrictionKind.gateTestFail, FrictionKind.retryExhausted]);
      expect(report.proposals.first.count, 3);
      expect(kinds, isNot(contains(FrictionKind.noChanges)));
    });

    test('render notes when there is nothing to propose', () {
      final out = summarize([rec(RiskLane.tiny, 'pass', [])]).render();
      expect(out, contains('Nothing to propose'));
      expect(out, contains('1 traces'));
    });
  });
}
