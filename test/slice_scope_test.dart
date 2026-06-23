import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  Issue issue(int number, {String body = '', String? parent}) => Issue(
    number: number,
    title: 't$number',
    body: parent == null ? body : '## Parent\n\n#$parent\n\n$body',
    labels: const [],
    url: 'u$number',
  );

  group('predictScope', () {
    test('extracts lib/test/bin/assets paths, bare or backtick-wrapped', () {
      final i = issue(
        1,
        body:
            'Edit `lib/features/x/hedging_card.dart` and '
            'test/widgets/hedging_card_test.dart plus '
            'assets/icons/icon_warning_triangle.svg and bin/tool.dart.',
      );
      expect(predictScope(i), {
        'lib/features/x/hedging_card.dart',
        'test/widgets/hedging_card_test.dart',
        'assets/icons/icon_warning_triangle.svg',
        'bin/tool.dart',
      });
    });

    test('returns empty when the body names only class names, no paths', () {
      expect(
        predictScope(issue(1, body: 'Adds a HedgingCard warming-up state.')),
        isEmpty,
      );
    });

    test('dedups repeated mentions of the same path', () {
      expect(predictScope(issue(1, body: 'lib/a.dart then lib/a.dart')), {
        'lib/a.dart',
      });
    });
  });

  group('implicitBlockers', () {
    // Synthetic scope + prd maps so the overlap logic is tested in isolation.
    Map<int, Set<int>> edges(
      List<Issue> ready,
      Map<int, Set<String>> scopes,
      Map<int, int> prd,
    ) => implicitBlockers(
      ready,
      (n) => scopes[n] ?? const {},
      (i) => prd[i.number]!,
    );

    final a = issue(10), b = issue(20), c = issue(30);

    test('same-PRD overlapping slices get a lower→higher edge only', () {
      final e = edges(
        [a, b],
        {
          10: {'lib/x.dart'},
          20: {'lib/x.dart'},
        },
        {10: 1, 20: 1},
      );
      expect(e[20], {10});
      expect(e[10], isNull);
    });

    test('same-PRD disjoint slices get no edge', () {
      final e = edges(
        [a, b],
        {
          10: {'lib/x.dart'},
          20: {'lib/y.dart'},
        },
        {10: 1, 20: 1},
      );
      expect(e, isEmpty);
    });

    test('an unknown (empty) scope overlaps every same-PRD sibling', () {
      // #20 has no predictable scope → conservatively serialised behind #10.
      final e = edges(
        [a, b],
        {
          10: {'lib/x.dart'},
        },
        {10: 1, 20: 1},
      );
      expect(e[20], {10});
    });

    test('cross-PRD slices never get an edge even when scopes overlap', () {
      final e = edges(
        [a, b],
        {
          10: {'lib/x.dart'},
          20: {'lib/x.dart'},
        },
        {10: 1, 20: 2},
      );
      expect(e, isEmpty);
    });

    test('every lower same-PRD overlapper is an edge', () {
      final e = edges(
        [a, b, c],
        {
          10: {'lib/x.dart'},
          20: {'lib/x.dart'},
          30: {'lib/x.dart'},
        },
        {10: 1, 20: 1, 30: 1},
      );
      expect(e[20], {10});
      expect(e[30], {10, 20});
    });
  });

  group('the nebula-app#365 fork', () {
    // #361 stands up the hedging card; #362 and #363 add states to it but each
    // declared only `## Blocked by #361`. #362 names the shared file, #363 names
    // none (class names only) → unknown scope. Both must be held behind their
    // overlapping lower sibling so neither forks off a stale base.
    final s361 = issue(
      361,
      parent: '357',
      body:
          'Builds `lib/features/portfolio/hedging_card.dart`, its preview, and '
          '`test/features/portfolio/hedging_card_test.dart`.',
    );
    final s362 = issue(
      362,
      parent: '357',
      body:
          'Adds the margin-call state to '
          '`lib/features/portfolio/hedging_card.dart`.',
    );
    final s363 = issue(
      363,
      parent: '357',
      body: 'Adds the warming-up state to the HedgingCard.',
    );

    test('#362 stacks on #361 and #363 is held behind both — no fork', () {
      final ready = [s361, s362, s363];
      final byNum = {for (final i in ready) i.number: i};
      final e = implicitBlockers(
        ready,
        (n) => predictScope(byNum[n]!),
        (i) => parentOf(i.body, i.number),
      );
      expect(e[362], {361});
      expect(e[363], {361, 362});
    });
  });
}
