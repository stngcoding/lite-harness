part of 'loop.dart';

/// How watching a PR's remote CI concluded (`_watchCi`). [ready] (green) and
/// [noCi] (a repo with no checks) both let the caller mark the PR ready; [failed]
/// (red past the fix budget) and [timedOut] (never settled) leave it a draft.
enum _CiOutcome { ready, noCi, failed, timedOut }

extension _CiWatcher on HarnessLoop {
  /// One CI auto-fix round: fetch the failed-job logs, run the ci-fixer, commit,
  /// re-run the local gates (a CI fix must not regress them), and re-push. Returns
  /// true when a fix was committed and pushed (keep watching); false when there is
  /// nothing more to try — no change, a secret leak, a local-gate regression, or a
  /// failed push — and the caller leaves the PR a draft.
  Future<bool> _runCiFix(
    int activeParent,
    String title,
    String url,
    String branch,
    List<int> failedRunIds,
    int round, {
    required String analyzeLog,
    required String testLog,
  }) async {
    _phase(
      HarnessPhase.implement,
      'PRD #$activeParent CI fix $round/${config.maxCiFixes}',
    );
    events.event(
      'CI_FIX',
      prd: activeParent,
      detail:
          'round=$round/${config.maxCiFixes} runs=${failedRunIds.join(',')}',
    );
    print(
      '  ${ansi.dim('↻ CI fix $round/${config.maxCiFixes} for PRD '
      '#$activeParent — feeding the failed CI logs back.')}',
    );
    final logs = await gh.ciFailedLogs(failedRunIds);
    final fix = await _runWithApiRetry(
      () => claude.implement(
        model: config.model,
        prompt: prompts.ciFixer(activeParent, title, config.base, logs: logs),
        systemAppend: rulesSystemPrompt,
      ),
      'CI fix #$activeParent',
    );
    _prdCostUsd += fix.result?.costUsd ?? 0;
    _recordCall(CallPhase.ciFix, fix, prd: activeParent, model: config.model);
    _abortIfFatal(fix, 'CI fix #$activeParent');

    if (!await git.hasDrift()) {
      print(
        ansi.dim(
          '  CI fix $round produced no changes — leaving the PR for a human.',
        ),
      );
      return false;
    }
    _phase(HarnessPhase.commit, 'PRD #$activeParent CI fix $round');
    await git.stageAll();
    final leaks = scanSecrets(await git.stagedDiff());
    if (leaks.isNotEmpty) {
      events.event(
        'SECRET_BLOCK',
        prd: activeParent,
        detail: 'ci-fix round=$round ${leaks.join('; ')}',
      );
      await git.resetHard('HEAD');
      print(
        ansi.red(
          '  CI fix $round added an apparent secret (${leaks.join('; ')}) — '
          'dropped; leaving the PR for a human.',
        ),
      );
      return false;
    }
    await git.commitStaged(
      'fix(#$activeParent): address CI failure (round $round)\n\n'
      'Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>',
    );

    // A CI fix that regresses the local gates is not trustworthy: leave the
    // commit (nothing rolled back) but hand off.
    final analyzeOk = await _gate(HarnessPhase.analyze, [
      'flutter',
      'analyze',
    ], analyzeLog);
    final testOk = await _gate(HarnessPhase.test, ['flutter', 'test'], testLog);
    _logGates(activeParent, null, analyzeOk: analyzeOk, testOk: testOk);
    if (!analyzeOk || !testOk) {
      print(
        ansi.red(
          '  CI fix $round regressed the local gates '
          '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}) — leaving the '
          'PR for a human.',
        ),
      );
      return false;
    }

    if (!await git.pushBranch(branch)) {
      events.event(
        'PUSH_FAIL',
        prd: activeParent,
        detail: 'branch=$branch ci-fix round=$round',
      );
      print(
        ansi.red(
          '  push failed after CI fix $round — leaving the PR for a human.',
        ),
      );
      return false;
    }
    return true;
  }

  /// Posts the CI-watch handoff comment ([ciHandoffComment]) on the draft PR.
  Future<void> _commentCiHandoff(String url, String reason) async {
    await gh.commentOnPr(url, ciHandoffComment(reason));
  }
}
