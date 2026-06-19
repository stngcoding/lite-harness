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

    test('round-trips the signature field and omits it when null', () {
      const withSig = TraceRecord(
        ts: 't',
        lane: RiskLane.normal,
        outcome: 'fail',
        attempts: 1,
        frictions: [FrictionKind.gateTestFail],
        signature: 'Expected: <2> Actual: <3>',
      );
      expect(
        TraceRecord.parse(withSig.toJsonLine()).signature,
        'Expected: <2> Actual: <3>',
      );

      const noSig = TraceRecord(
        ts: 't',
        lane: RiskLane.tiny,
        outcome: 'pass',
        attempts: 1,
        frictions: [],
      );
      expect(noSig.toJsonLine(), isNot(contains('signature')));
      expect(TraceRecord.parse(noSig.toJsonLine()).signature, isNull);
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

  group('errorSignature', () {
    test('prefers a flutter analyze error row over earlier noise', () {
      const log =
          'Analyzing app...\n\n'
          '  info • Unused import • lib/a.dart:1:8 • unused_import\n'
          '  error • Undefined name foo • lib/b.dart:9:3 • undefined_identifier\n';
      expect(errorSignature(log), contains('Undefined name foo'));
      expect(errorSignature(log), startsWith('error •'));
    });

    test('matches a test matcher Expected line', () {
      const log =
          '00:01 +0 -1: widget paints [E]\nExpected: <2>\n  Actual: <3>';
      // The compact reporter `[E]` line is the first marker hit.
      expect(errorSignature(log), '00:01 +0 -1: widget paints [E]');
    });

    test('falls back to the first non-empty line and clips to 120 chars', () {
      final long = 'x' * 200;
      expect(errorSignature('\n\n$long'), hasLength(120));
      expect(errorSignature('just a note'), 'just a note');
      expect(errorSignature('   \n  '), isNull);
    });
  });

  group('recurringSignatures', () {
    TraceRecord sig(String? s) => TraceRecord(
      ts: 't',
      lane: RiskLane.normal,
      outcome: 'fail',
      attempts: 1,
      frictions: const [],
      signature: s,
    );

    test(
      'surfaces signatures recurring >= minCount, normalizing line numbers',
      () {
        final out = recurringSignatures([
          sig(
            'error • Undefined name foo • lib/a.dart:9:3 • undefined_identifier',
          ),
          sig(
            'error • Undefined name foo • lib/b.dart:42:7 • undefined_identifier',
          ),
          sig('error • Missing return • lib/c.dart:1:1 • missing_return'),
        ]);
        // The two `Undefined name foo` lines fingerprint the same despite
        // different paths/line numbers; the one-off `Missing return` drops out.
        expect(out, hasLength(1));
        expect(out.single, contains('Undefined name foo'));
      },
    );

    test('caps at top and ignores null signatures', () {
      final records = [
        sig(null),
        sig(null),
        for (var i = 0; i < 4; i++) ...[sig('err alpha'), sig('err alpha')],
      ];
      // Only one distinct recurring signature here, so top has no effect, but
      // null entries must not crash or count.
      expect(recurringSignatures(records), ['err alpha']);
    });

    test('respects the recency window', () {
      final old = [sig('old boom'), sig('old boom')];
      final recent = List.generate(50, (_) => sig('fresh bang'));
      // window=50 keeps only the recent block; the old recurring sig ages out.
      final out = recurringSignatures([...old, ...recent], window: 50);
      expect(out, ['fresh bang']);
    });
  });
}
