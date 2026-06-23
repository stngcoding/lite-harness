import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

Issue _issue(int number, List<String> labels) => Issue(
  number: number,
  title: 'issue-$number',
  body: 'body-$number',
  labels: labels,
  url: 'u/$number',
);

List<int> _numbers(List<Issue> issues) =>
    issues.map((i) => i.number).toList()..sort();

void main() {
  group('IssueStateOverlay.reconcile', () {
    test('is inert until the harness records a write', () {
      final overlay = IssueStateOverlay();
      final raw = [
        _issue(1, ['ready-for-agent']),
        _issue(2, ['ready-for-agent']),
      ];
      expect(
        _numbers(
          overlay.reconcile(raw, label: 'ready-for-agent', state: 'open'),
        ),
        [1, 2],
      );
    });

    test('a confirmed close hides the issue from any open read', () {
      final overlay = IssueStateOverlay()..recordClosed(280);
      final raw = [
        _issue(280, ['ready-for-agent']),
      ];
      expect(
        overlay.reconcile(raw, label: 'ready-for-agent', state: 'open'),
        isEmpty,
      );
    });

    test('a closed issue still surfaces in a state=all read', () {
      final overlay = IssueStateOverlay()..recordClosed(280);
      final raw = [
        _issue(280, ['ready-for-agent']),
      ];
      expect(
        _numbers(
          overlay.reconcile(raw, label: 'ready-for-agent', state: 'all'),
        ),
        [280],
        reason:
            'closed issues legitimately appear when the caller asks for all',
      );
    });

    test(
      'dropping the agent label removes it from the ready-for-agent read',
      () {
        final overlay = IssueStateOverlay()..recordDroppedAgentLabel(367);
        final raw = [
          _issue(367, ['ready-for-agent']),
        ];
        expect(
          overlay.reconcile(raw, label: 'ready-for-agent', state: 'open'),
          isEmpty,
        );
      },
    );

    test('relabel-for-human drops the issue from the ready-for-agent read', () {
      final overlay = IssueStateOverlay()..recordRelabeledForHuman(42);
      final raw = [
        _issue(42, ['ready-for-agent']),
      ];
      expect(
        overlay.reconcile(raw, label: 'ready-for-agent', state: 'open'),
        isEmpty,
      );
    });

    test('relabel-for-human surfaces the issue in the ready-for-human read '
        'even before the index lists it', () {
      final overlay = IssueStateOverlay()
        // The issue was seen as ready-for-agent, then relabeled. The
        // ready-for-human list has not caught up, so raw omits it — the overlay
        // must add it back so it still blocks the PR.
        ..observe([
          _issue(42, ['ready-for-agent']),
        ])
        ..recordRelabeledForHuman(42);
      final reconciled = overlay.reconcile(
        const [],
        label: 'ready-for-human',
        state: 'open',
      );
      expect(_numbers(reconciled), [42]);
      expect(reconciled.single.labels, contains('ready-for-human'));
    });

    test('an unseen relabeled issue is not fabricated into the read', () {
      // Without a prior observe there is no issue to reconstruct, so the overlay
      // stays subtractive-only rather than inventing a body-less phantom.
      final overlay = IssueStateOverlay()..recordRelabeledForHuman(99);
      expect(
        overlay.reconcile(const [], label: 'ready-for-human', state: 'open'),
        isEmpty,
      );
    });

    test('a confirmed close wins over a later relabel record', () {
      final overlay = IssueStateOverlay()
        ..observe([
          _issue(7, ['ready-for-agent']),
        ])
        ..recordClosed(7);
      expect(
        overlay.reconcile(
          [
            _issue(7, ['ready-for-agent']),
          ],
          label: 'ready-for-agent',
          state: 'open',
        ),
        isEmpty,
      );
    });

    test('untouched issues pass through unchanged alongside a closed one', () {
      final overlay = IssueStateOverlay()..recordClosed(2);
      final raw = [
        _issue(1, ['ready-for-agent']),
        _issue(2, ['ready-for-agent']),
        _issue(3, ['ready-for-agent']),
      ];
      expect(
        _numbers(
          overlay.reconcile(raw, label: 'ready-for-agent', state: 'open'),
        ),
        [1, 3],
      );
    });
  });
}
