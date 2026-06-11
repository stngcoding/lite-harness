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
