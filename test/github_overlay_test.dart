import 'dart:convert';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

/// A `ProcessRunner` that emulates the slice of `gh` the PR gate touches, with
/// one faithful twist: GitHub's issue-list index is eventually consistent, so
/// `gh issue list --label ready-for-agent --state open` keeps returning an issue
/// for seconds *after* it was closed. Here that lag never clears — the worst
/// case — so a correct harness must reconcile the read against its own write.
class LaggyProc extends ProcessRunner {
  LaggyProc({this.closeExitCode = 0});

  /// Exit code `gh issue close` returns; non-zero models a close that did not
  /// actually take (rate limit / transient), which must NOT be trusted.
  final int closeExitCode;
  final List<int> closesAttempted = [];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (arguments.contains('list')) {
      final label = _valueAfter(arguments, '--label');
      final state = _valueAfter(arguments, '--state');
      // The lagging index: #280 is reported as an open ready-for-agent issue
      // unconditionally, even once it has been closed.
      final stale = label == 'ready-for-agent' && state == 'open'
          ? [
              {
                'number': 280,
                'title': 'Add isPalindrome(String) helper',
                'body': 'no parent',
                'labels': [
                  {'name': 'ready-for-agent'},
                ],
                'url': 'u/280',
              },
            ]
          : const [];
      return ProcResult(0, jsonEncode(stale), '');
    }
    if (arguments.contains('close')) {
      closesAttempted.add(int.parse(arguments[arguments.indexOf('close') + 1]));
      return ProcResult(closeExitCode, '', closeExitCode == 0 ? '' : 'error');
    }
    // issue edit / comment / anything else: benign success.
    return const ProcResult(0, '', '');
  }

  String _valueAfter(List<String> args, String flag) =>
      args[args.indexOf(flag) + 1];
}

void main() {
  test(
    'a confirmed close hides the issue from later open reads despite list lag',
    () async {
      final gh = GhCli(LaggyProc(), 'o/r');

      // Before the close, the issue is a legitimate open sub.
      expect(
        (await gh.issuesWithLabel(
          'ready-for-agent',
          'open',
        )).map((i) => i.number),
        [280],
      );

      await gh.closeIssue(280, 'Verified by AFK loop.');

      // After a *confirmed* close, the gate's read must come back empty even
      // though `gh issue list` still reports #280 — the exact stale-read that
      // left PRD #367's drained branch un-PR'd (open_subs=1 [#367]).
      expect(
        await gh.issuesWithLabel('ready-for-agent', 'open'),
        isEmpty,
        reason: 'overlay must hide the just-closed issue from the lagging list',
      );
    },
  );

  test('a close that did not succeed is not trusted to hide the issue', () async {
    final gh = GhCli(LaggyProc(closeExitCode: 1), 'o/r');

    await gh.closeIssue(280, 'Verified by AFK loop.');

    // The close call failed, so the issue is genuinely still open: the overlay
    // must NOT mask it, or the gate would open a PR that never closes its issue.
    expect(
      (await gh.issuesWithLabel(
        'ready-for-agent',
        'open',
      )).map((i) => i.number),
      [280],
      reason: 'only a confirmed write may be trusted over the live list',
    );
  });
}
