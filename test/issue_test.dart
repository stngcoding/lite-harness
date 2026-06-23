import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('priorityScore', () {
    test('ranks label tiers from critical to unlabeled', () {
      expect(priorityScore(['Critical']), 0);
      expect(priorityScore(['P1']), 1);
      expect(priorityScore(['bug']), 2);
      expect(priorityScore(['Medium']), 3);
      expect(priorityScore(['enhancement']), 4);
      expect(priorityScore(['p3']), 5);
      expect(priorityScore(['docs']), 6);
      expect(priorityScore([]), 6);
    });

    test('best tier wins when multiple labels apply', () {
      expect(priorityScore(['enhancement', 'blocker']), 0);
    });
  });

  group('sortReady', () {
    Issue issue(int number, List<String> labels) =>
        Issue(number: number, title: 't', body: '', labels: labels, url: 'u');

    test('orders by priority score, then issue number', () {
      final sorted = sortReady([
        issue(30, []),
        issue(20, ['bug']),
        issue(10, []),
        issue(40, ['critical']),
      ]);
      expect(sorted.map((i) => i.number), [40, 20, 10, 30]);
    });
  });

  group('Issue.fromJson', () {
    test('parses gh issue JSON with null body', () {
      final parsed = Issue.fromJson({
        'number': 7,
        'title': 'T',
        'body': null,
        'labels': [
          {'name': 'bug'},
        ],
        'url': 'https://example.com/7',
      });
      expect(parsed.number, 7);
      expect(parsed.body, '');
      expect(parsed.labels, ['bug']);
    });
  });

  group('parentOf', () {
    test('reads the first issue number in the Parent section', () {
      expect(parentOf('## Parent\n\n#42\n', 10), 42);
    });

    test('reads full issue URLs', () {
      expect(parentOf('## Parent\nhttps://github.com/o/r/issues/77\n', 10), 77);
    });

    test('falls back to the issue own number when no Parent section', () {
      expect(parentOf('Just a description.', 10), 10);
    });

    test('ignores references outside the Parent section', () {
      expect(parentOf('## Parent\n#12\n\n## Notes\n#99\n', 10), 12);
    });
  });

  group('blockersOf', () {
    test('lists issue numbers from the Blocked by section', () {
      expect(blockersOf('## Blocked by\n- #3\n- #5\n'), [3, 5]);
    });

    test('returns empty when no Blocked by section', () {
      expect(blockersOf('## Parent\n#3\n'), isEmpty);
    });

    test('ignores references outside the Blocked by section', () {
      expect(blockersOf('## Blocked by\n#3\n\n## Context\nsee #8\n'), [3]);
    });

    test('"None" with prose mentioning issues yields no blockers', () {
      expect(
        blockersOf('## Blocked by\nNone — can start on the PR #338 branch.\n'),
        isEmpty,
      );
      expect(
        blockersOf('## Blocked by\nNone - spine for #337/#338/#339.\n'),
        isEmpty,
      );
    });
  });

  group('umbrellaNumbers', () {
    Issue issue(int number, String body) =>
        Issue(number: number, title: 't', body: body, labels: [], url: 'u');

    test('flags a parent-less issue that other issues declare as parent', () {
      final umbrellas = umbrellaNumbers([
        issue(263, 'PRD spec, no Parent section'),
        issue(264, '## Parent\n#263\n'),
        issue(265, '## Parent\n#263\n'),
      ]);
      expect(umbrellas, {263});
    });

    test('a parent-less issue with no children is not an umbrella', () {
      expect(umbrellaNumbers([issue(10, 'standalone, no Parent')]), isEmpty);
    });

    test('does not flag an issue solely from its own self-parent', () {
      expect(umbrellaNumbers([issue(10, 'no Parent section')]), isEmpty);
    });

    test('collects multiple distinct umbrellas', () {
      final umbrellas = umbrellaNumbers([
        issue(1, '## Parent\n#100\n'),
        issue(2, '## Parent\n#200\n'),
        issue(3, '## Parent\n#100\n'),
      ]);
      expect(umbrellas, {100, 200});
    });
  });

  group('eligibleSlices', () {
    Issue issue(int number, String body, [List<String> labels = const []]) =>
        Issue(number: number, title: 't', body: body, labels: labels, url: 'u');

    test('a slice is eligible only when every blocker is satisfied', () {
      final ready = [
        issue(10, '## Blocked by\n#9\n'),
        issue(11, '## Blocked by\nNone\n'),
      ];
      // #9 is not satisfied → #10 is blocked; #11 has no blockers → eligible.
      expect(
        eligibleSlices(ready, satisfied: {}, excluded: {}).map((i) => i.number),
        [11],
      );
      // Once #9 is satisfied, #10 unblocks too (ordered by number, same tier).
      expect(
        eligibleSlices(
          ready,
          satisfied: {9},
          excluded: {},
        ).map((i) => i.number),
        [10, 11],
      );
    });

    test('umbrellas and excluded issues are never scheduled', () {
      final ready = [
        issue(100, 'PRD spec, no Parent'), // umbrella: #101 declares it parent
        issue(101, '## Parent\n#100\n'),
        issue(102, '## Parent\n#100\n'),
      ];
      // #100 dropped as umbrella; #101 excluded (in flight) → only #102 left.
      expect(
        eligibleSlices(
          ready,
          satisfied: {},
          excluded: {101},
        ).map((i) => i.number),
        [102],
      );
    });

    test('orders eligible slices by priority then number', () {
      final ready = [
        issue(30, 'no blockers'),
        issue(20, 'no blockers', ['critical']),
        issue(10, 'no blockers'),
      ];
      expect(
        eligibleSlices(ready, satisfied: {}, excluded: {}).map((i) => i.number),
        [20, 10, 30],
      );
    });
  });

  group('slugify', () {
    test('lowercases and replaces runs of non-alphanumerics with one dash', () {
      expect(slugify('Fix: WebSocket reconnect!!'), 'fix-websocket-reconnect');
    });

    test('trims leading and trailing dashes', () {
      expect(slugify('  [Bug] crash on open  '), 'bug-crash-on-open');
    });

    test('truncates to 50 chars without a dangling dash', () {
      final slug = slugify('a' * 49 + ' tail that exceeds the limit');
      expect(slug.length, lessThanOrEqualTo(50));
      expect(slug.endsWith('-'), isFalse);
    });
  });
}
