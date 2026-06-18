import 'dart:io';

import 'ansi.dart';
import 'claude.dart';
import 'config.dart';
import 'event_log.dart';
import 'git.dart';
import 'github.dart';
import 'issue.dart';
import 'phase.dart';
import 'proc.dart';
import 'prompts.dart';
import 'test_scope.dart';
import 'verdict.dart';

const _analyzeLog = '/tmp/ralph-analyze.log';
const _testLog = '/tmp/ralph-test.log';

class HarnessLoop {
  HarnessLoop({
    required this.config,
    required this.gh,
    required this.git,
    required this.claude,
    required this.proc,
    required this.prompts,
    this.rulesSystemPrompt = '',
    EventLog? events,
    Ansi? ansi,
    this.apiRetryBackoff = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 45),
    ],
  }) : events = events ?? EventLog(),
       ansi = ansi ?? Ansi.forStdout();

  final Config config;
  final GhCli gh;
  final GitOps git;
  final ClaudeRunner claude;
  final ProcessRunner proc;
  final PromptLibrary prompts;

  /// Target-repo `.claude/rules/*.md`, flattened into one blob and injected into
  /// the implementer's system prompt via `--append-system-prompt`. Loaded once
  /// at startup; `''` when the target ships no root-level rules. See
  /// `loadRulesSystemPrompt` (`rules.dart`).
  final String rulesSystemPrompt;

  final EventLog events;
  final Ansi ansi;

  /// Backoff between retries of a `claude` run that hit a *transient* API
  /// failure (overload/5xx, dropped stream, exhausted internal retry). One entry
  /// per retry, so the length is the retry cap. A hard failure (rate limit,
  /// auth, billing) is never retried. Injectable so tests don't actually sleep.
  final List<Duration> apiRetryBackoff;

  /// Running `claude` API spend (USD) for the PRD currently being drained,
  /// summed from each slice's `result` event. Reset when a new PRD starts.
  double _prdCostUsd = 0;

  /// Issue numbers already consumed in this run (processed as a sub, or dropped
  /// as an umbrella). GitHub's issue list is eventually consistent: right after
  /// `closeIssue`/`relabelForHuman`/`dropAgentLabel`, the next `gh issue list`
  /// can still return the just-handled issue (a stale read), which would make
  /// the loop implement it a second time. This in-memory guard makes selection
  /// independent of that read-after-write lag.
  final Set<int> _handled = {};

  /// Prints the active-stage marker, e.g. `▶ IMPLEMENT — #123 fix login`.
  void _phase(HarnessPhase phase, [String? detail]) =>
      print(phase.marker(ansi, detail));

  /// Aborts the whole loop when [run] hit an unrecoverable condition (rate
  /// limit, auth/billing, streaming death) — every later `claude` call would
  /// fail the same way, so there is no point grinding through the queue. A
  /// per-task failure (max-turns, bad code) is not fatal and returns normally.
  void _abortIfFatal(ClaudeRun run, String context) {
    // A transient API failure that survived every retry is no longer
    // recoverable, so it aborts here too — alongside the hard failures.
    final fatal = run.fatalError ?? run.transientApiError;
    if (fatal != null) throw ClaudeAbort('$context — $fatal');
  }

  /// Runs a `claude` call, retrying on a *transient* API failure (overload/5xx,
  /// dropped stream, exhausted internal retry) with [apiRetryBackoff]. Returns
  /// as soon as a run is clean or hard-fatal; a transient run that survives the
  /// last retry is returned for the caller's [_abortIfFatal] to abort on.
  Future<ClaudeRun> _runWithApiRetry(
    Future<ClaudeRun> Function() call,
    String context,
  ) async {
    var run = await call();
    for (var i = 0; i < apiRetryBackoff.length; i++) {
      final transient = run.transientApiError;
      if (transient == null) return run;
      final wait = apiRetryBackoff[i];
      events.event(
        'API_RETRY',
        detail:
            '$context attempt=${i + 1}/${apiRetryBackoff.length} '
            'wait=${wait.inSeconds}s — $transient',
      );
      print(
        ansi.dim(
          '  ⚠ API trouble ($transient) — retry ${i + 1}/'
          '${apiRetryBackoff.length} in ${wait.inSeconds}s.',
        ),
      );
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      run = await call();
    }
    return run;
  }

  Future<int> run() async {
    if (config.dryRun) return _dryRun();
    events.event(
      'START',
      detail:
          'repo=${config.repo} base=${config.base} state=${config.state}'
          '${config.issueNumber != null ? ' issue=${config.issueNumber}' : ''}',
    );
    try {
      if (config.reviewPr != null) {
        final code = await _reviewPr(config.reviewPr!);
        events.event('DONE');
        return code;
      }
      if (config.issueNumber != null) {
        final code = await _runSingle(config.issueNumber!);
        events.event('DONE');
        return code;
      }

      var processed = 0;
      var capHit = false;
      while (true) {
        final activeParent = await _selectActivePrd();
        if (activeParent == null) break;
        processed += await _drainPrd(activeParent, processed);
        if (config.iterations != null && processed >= config.iterations!) {
          capHit = true;
          break;
        }
      }
      if (!capHit) {
        // Queue is drained. A PRD whose last failed sub was resolved (closed in
        // a later run or by a human) never re-enters selection, so its branch
        // would otherwise sit un-PR'd forever. Sweep for those and ship them.
        await _shipStrandedPrds();
        print('No processable ready-for-agent issues remain. Done.');
      }
      events.event('DONE');
      return 0;
    } on ClaudeAbort catch (e) {
      events.event('ABORT', detail: e.message);
      stderr.writeln(ansi.red('✗ Fatal: ${e.message}'));
      stderr.writeln(
        'claude cannot continue — aborting the AFK loop. '
        'In-flight work is left uncommitted for a human.',
      );
      return 2;
    }
  }

  Future<int> _dryRun() async {
    final ready = await gh.readyIssues(config.state);
    if (ready.isEmpty) {
      print('No ready-for-agent issues found.');
      return 0;
    }
    final umbrellas = umbrellaNumbers(ready);
    int? activeParent;
    final processable = <Issue>[];
    final blocked = <Issue>[];
    for (final issue in ready) {
      if (await gh.allBlockersClosed(issue.body)) {
        processable.add(issue);
        activeParent ??= parentOf(issue.body, issue.number);
      } else {
        blocked.add(issue);
      }
    }
    if (activeParent == null) {
      print('All ${ready.length} ready issues are blocked. Nothing to do.');
      return 0;
    }
    final title = await gh.issueTitle(activeParent);
    print('Active PRD #$activeParent: $title');
    print('Branch:     $activeParent-${slugify(title)}');
    print('');
    if (umbrellas.contains(activeParent)) {
      print('Umbrella PRD #$activeParent — not implemented; closed by its PR.');
      print('');
    }
    print('Would process (in order):');
    for (final issue in processable.where(
      (i) =>
          parentOf(i.body, i.number) == activeParent &&
          !umbrellas.contains(i.number),
    )) {
      print(
        '  #${issue.number} [p${priorityScore(issue.labels)}] '
        '${issue.title}',
      );
    }
    final otherPrds = processable
        .where((i) => parentOf(i.body, i.number) != activeParent)
        .toList();
    if (otherPrds.isNotEmpty) {
      print('');
      print('Queued behind this PRD:');
      for (final issue in otherPrds) {
        print(
          '  #${issue.number} [p${priorityScore(issue.labels)}] '
          '${issue.title} (PRD #${parentOf(issue.body, issue.number)})',
        );
      }
    }
    if (blocked.isNotEmpty) {
      print('');
      print('Blocked (open blockers):');
      for (final issue in blocked) {
        print(
          '  #${issue.number} ${issue.title} '
          '(blocked by ${blockersOf(issue.body).map((n) => '#$n').join(', ')})',
        );
      }
    }
    return 0;
  }

  Future<int> _runSingle(int number) async {
    final ready = await gh.readyIssues(config.state);
    Issue? issue;
    for (final candidate in ready) {
      if (candidate.number == number) {
        issue = candidate;
        break;
      }
    }
    if (issue == null) {
      stderr.writeln(
        'Issue #$number is not in the ready-for-agent queue '
        '(state=${config.state}).',
      );
      return 1;
    }
    if (!await gh.allBlockersClosed(issue.body)) {
      stderr.writeln('Issue #$number still has open blockers.');
      return 1;
    }
    final parent = parentOf(issue.body, issue.number);
    if (!await _checkoutPrdBranch(parent)) return 1;
    _prdCostUsd = 0;
    final passed = await _processSub(issue);
    return passed ? 0 : 1;
  }

  /// `--review-pr`: skip the whole implement loop and review an existing PR.
  /// Checks out the PR's head, runs the full suite + the holistic diff-verifier
  /// over `origin/<pr-base>..HEAD`, comments the verdict, and marks the PR ready
  /// only when the suite is green and the review passes (a red result just
  /// comments and leaves the PR untouched). Returns 0 on a green verdict.
  Future<int> _reviewPr(String prRef) async {
    final info = await gh.prInfo(prRef);
    if (info == null) {
      stderr.writeln('PR $prRef not found in ${config.repo}.');
      return 1;
    }

    const rule = '════════════════════════════════════════════════════';
    print('');
    print(ansi.cyan(rule));
    _phase(HarnessPhase.checkout, 'PR #${info.number}');
    print('  ${ansi.bold('PR #${info.number}')}: ${info.title}');
    print('  Branch: ${ansi.cyan(info.head)} → base ${info.base}');
    print(ansi.cyan(rule));

    final parked = await git.parkDrift();
    if (parked != null) print('  Parked uncommitted drift in stash: $parked');
    if (!await gh.checkoutPr(prRef)) {
      events.event('CHECKOUT_FAIL', prd: info.number, detail: 'pr=${info.url}');
      stderr.writeln('  cannot checkout PR #${info.number}; aborting.');
      return 1;
    }
    await git.fetch(info.base);
    _prdCostUsd = 0;
    events.event('PR_REVIEW_START', prd: info.number, detail: 'pr=${info.url}');

    final analyzeOk = await _gate(HarnessPhase.analyze, [
      'flutter',
      'analyze',
    ], _analyzeLog);
    final testOk = await _gate(HarnessPhase.test, [
      'flutter',
      'test',
    ], _testLog);
    _logGates(info.number, null, analyzeOk: analyzeOk, testOk: testOk);

    _phase(HarnessPhase.review, 'PR #${info.number}');
    final review = await _runWithApiRetry(
      () => claude.verify(
        prompts.prVerifier(
          info.number,
          info.title,
          info.base,
          repo: config.repo,
          prRef: info.url,
        ),
      ),
      'PR review #${info.number}',
    );
    _prdCostUsd += review.result?.costUsd ?? 0;
    _abortIfFatal(review, 'PR review #${info.number}');
    final verdict = review.transcript;
    events.event(
      'PR_REVIEW',
      prd: info.number,
      detail: hasPassVerdict(verdict) ? 'pass' : 'fail',
    );
    final reviewSummary = review.result == null
        ? ''
        : '\n\n_Review: ${review.result!.summary}._';
    final suiteLine =
        'Full suite: analyze=${analyzeOk ? 'pass' : 'fail'} '
        'test=${testOk ? 'pass' : 'fail'}.';
    final green = analyzeOk && testOk && hasPassVerdict(verdict);
    await gh.commentOnPr(
      info.url,
      '**AFK PR review (diff-verifier)**\n\n$suiteLine\n\n'
      '${reviewComment(verdict)}$reviewSummary'
      '\n\n_AFK review spend: \$${_prdCostUsd.toStringAsFixed(4)}._',
    );
    if (green) {
      await gh.markPrReady(info.url);
      events.event('PR_READY', prd: info.number);
      print('  ${ansi.green('✓ Full suite + PR review PASS → marked ready.')}');
    } else {
      events.event(
        'PR_DRAFT',
        prd: info.number,
        detail:
            'analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0} '
            'review=${hasPassVerdict(verdict) ? 1 : 0}',
      );
      print(
        ansi.red(
          '  ✗ PR left as-is '
          '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0} '
          'review=${hasPassVerdict(verdict) ? 1 : 0}).',
        ),
      );
    }
    return green ? 0 : 1;
  }

  Future<int?> _selectActivePrd() async {
    for (final issue in await gh.readyIssues(config.state)) {
      if (_handled.contains(issue.number)) continue;
      if (await gh.allBlockersClosed(issue.body)) {
        return parentOf(issue.body, issue.number);
      }
    }
    return null;
  }

  Future<bool> _checkoutPrdBranch(int activeParent) async {
    final title = await gh.issueTitle(activeParent);
    final branch = '$activeParent-${slugify(title)}';

    const rule = '════════════════════════════════════════════════════';
    print('');
    print(ansi.cyan(rule));
    _phase(HarnessPhase.checkout, 'PRD #$activeParent');
    print('  ${ansi.bold('PRD #$activeParent')}: $title');
    print('  Branch: ${ansi.cyan(branch)}');
    print(ansi.cyan(rule));

    final parked = await git.parkDrift();
    if (parked != null) print('  Parked uncommitted drift in stash: $parked');
    await git.fetch(config.base);

    if (await git.branchExists(branch)) {
      if (!await git.checkout(branch)) {
        events.event(
          'CHECKOUT_FAIL',
          prd: activeParent,
          detail: 'branch=$branch',
        );
        print('  cannot checkout $branch; skipping PRD');
        return false;
      }
    } else if (!await git.checkoutNew(branch, 'origin/${config.base}')) {
      events.event(
        'CHECKOUT_FAIL',
        prd: activeParent,
        detail: 'branch=$branch',
      );
      print('  cannot create $branch; skipping PRD');
      return false;
    }
    events.event('CHECKOUT', prd: activeParent, detail: 'branch=$branch');
    return true;
  }

  /// Returns the number of sub-issues processed.
  Future<int> _drainPrd(int activeParent, int alreadyProcessed) async {
    if (!await _checkoutPrdBranch(activeParent)) return 0;

    _prdCostUsd = 0;
    var count = 0;
    while (true) {
      final ready = await gh.readyIssues(config.state);
      final umbrellas = umbrellaNumbers(ready);
      Issue? sub;
      for (final issue in ready) {
        if (parentOf(issue.body, issue.number) != activeParent) continue;
        if (_handled.contains(issue.number)) continue;
        if (umbrellas.contains(issue.number)) {
          await gh.dropAgentLabel(issue.number);
          _handled.add(issue.number);
          events.event('UMBRELLA_DROP', prd: activeParent, issue: issue.number);
          print(
            '  ${ansi.dim('#${issue.number} is an umbrella PRD (has sub-issues) '
            '→ dropped from agent queue; closed by its PR.')}',
          );
          continue;
        }
        if (!await gh.allBlockersClosed(issue.body)) continue;
        sub = issue;
        break;
      }
      if (sub == null) break;
      await _processSub(sub);
      count++;
      final total = alreadyProcessed + count;
      if (config.iterations != null && total >= config.iterations!) {
        return count;
      }
    }

    await _maybeOpenPr(activeParent);
    return count;
  }

  /// Ships any PRD branch whose work is done but never got a PR — typically a
  /// PRD that had a failed sub which was later resolved (closed in a subsequent
  /// run or by a human) without re-entering the `ready-for-agent` queue, so
  /// [_drainPrd] never ran again to PR it. Idempotent: branches that already
  /// have an open PR, still have open subs, or whose parent is closed are
  /// skipped, so re-running the harness on a loop never re-opens or spams.
  Future<void> _shipStrandedPrds() async {
    for (final entry in await _strandedPrds()) {
      final parent = entry.key;
      final branch = entry.value;
      final parked = await git.parkDrift();
      if (parked != null) print('  Parked uncommitted drift in stash: $parked');
      if (!await git.checkout(branch)) {
        events.event(
          'STRANDED_SKIP',
          prd: parent,
          detail: 'checkout-failed branch=$branch',
        );
        print('  cannot checkout $branch; skipping stranded PRD #$parent');
        continue;
      }
      _prdCostUsd = 0;
      print('');
      events.event('STRANDED_SHIP', prd: parent, detail: 'branch=$branch');
      print(
        '  ${ansi.cyan('Shipping stranded PRD #$parent')} '
        '(all sub-issues resolved, branch $branch)',
      );
      await _maybeOpenPr(parent);
    }
  }

  /// Local PRD branches (`<parent#>-<slug>`) that are ready to PR but have not
  /// been: parent still OPEN, no open managed subs, and no existing open PR.
  Future<List<MapEntry<int, String>>> _strandedPrds() async {
    final branchByParent = <int, String>{};
    final chunkBranch = RegExp(r'-chunk-\d+-of-\d+-');
    for (final branch in await git.localBranches()) {
      final match = RegExp(r'^(\d+)-').firstMatch(branch);
      if (match == null) continue;
      final parent = int.parse(match.group(1)!);
      // Prefer the canonical `<parent>-<slug>` branch over a stacked-PR chunk
      // branch: it holds the whole PRD and is where `_maybeOpenPr` must run to
      // rebuild (or fill the gaps in) the stack.
      final existing = branchByParent[parent];
      if (existing == null ||
          (chunkBranch.hasMatch(existing) && !chunkBranch.hasMatch(branch))) {
        branchByParent[parent] = branch;
      }
    }
    final stranded = <MapEntry<int, String>>[];
    for (final entry in branchByParent.entries) {
      if (await gh.issueState(entry.key) != 'OPEN') continue;
      if (await gh.openPrForBranch(entry.value) != null) continue;
      if ((await _openSubsOf(entry.key)).isNotEmpty) continue;
      stranded.add(entry);
    }
    return stranded;
  }

  /// The PRD's sub-issues still in flight: open issues parented to
  /// [activeParent] that the harness manages (`ready-for-agent` or
  /// `ready-for-human`). A previously-failed sub that has since been closed is
  /// no longer here, so it stops blocking the PR — this is the live-state
  /// replacement for the old sticky in-run `prdFailed` flag.
  Future<List<Issue>> _openSubsOf(int activeParent) async {
    final byNumber = <int, Issue>{};
    for (final label in const ['ready-for-agent', 'ready-for-human']) {
      for (final issue in await gh.issuesWithLabel(label, 'open')) {
        if (parentOf(issue.body, issue.number) == activeParent) {
          byNumber[issue.number] = issue;
        }
      }
    }
    return byNumber.values.toList();
  }

  Future<bool> _processSub(Issue issue) async {
    _handled.add(issue.number);
    final parent = parentOf(issue.body, issue.number);
    final prdRef = parent == issue.number ? null : parent;
    events.event('ISSUE_START', prd: prdRef, issue: issue.number);
    final comments = await gh.issueComments(issue.number);

    final issuePhase = phaseOf(issue.body);
    const rule = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━';
    print(ansi.dim(rule));
    print('  ${ansi.bold('Issue #${issue.number}')}: ${issue.title}');
    if (issuePhase != null) print('  Phase: ${ansi.dim(issuePhase)}');
    print('  ${ansi.dim(issue.url)}');
    print(ansi.dim(rule));

    final baseline = await git.head();

    // One sub-issue gets up to `config.maxAttempts` shots: implement → commit
    // → gate. A failing attempt is rolled back to [baseline] and the agent is
    // re-run with the failing analyze/test logs fed back via `{{RETRY}}`, so it
    // fixes forward instead of repeating the same mistake. Only after every
    // attempt fails does the issue get tagged and handed to a human.
    var analyzeOk = false;
    var testOk = false;
    var implementSummary = '';
    var retry = '';

    for (var attempt = 1; attempt <= config.maxAttempts; attempt++) {
      if (attempt > 1) {
        print(
          '  ${ansi.dim('↻ retry $attempt/${config.maxAttempts} for '
          '#${issue.number} — feeding the failing logs back to the agent.')}',
        );
        await git.resetHard(baseline);
      }

      _phase(
        HarnessPhase.implement,
        '#${issue.number} ${issue.title}'
        '${attempt > 1 ? ' (attempt $attempt/${config.maxAttempts})' : ''}',
      );
      events.event(
        'IMPLEMENT',
        prd: prdRef,
        issue: issue.number,
        detail: 'attempt=$attempt/${config.maxAttempts}',
      );
      final run = await _runWithApiRetry(
        () => claude.implement(
          model: config.model,
          prompt: prompts.implementer(
            issue: issue,
            comments: comments,
            retry: retry,
          ),
          systemAppend: rulesSystemPrompt,
        ),
        'Implement #${issue.number}',
      );
      _prdCostUsd += run.result?.costUsd ?? 0;
      _abortIfFatal(run, 'Implement #${issue.number}');
      implementSummary = run.result == null
          ? ''
          : '\n\nImplement: ${run.result!.summary}.';
      print('');

      if (!await git.hasDrift()) {
        // No uncommitted changes — current state may already satisfy the issue
        // (e.g. a prior human commit resolved it), or the agent simply produced
        // nothing this attempt. Gate it: green means done; otherwise retry.
        analyzeOk = await _gate(HarnessPhase.analyze, [
          'flutter',
          'analyze',
        ], _analyzeLog);
        testOk = await _scopedTestGate(baseline, issue.number);
        _logGates(prdRef, issue.number, analyzeOk: analyzeOk, testOk: testOk);
        if (analyzeOk && testOk) {
          await gh.closeIssue(
            issue.number,
            'No new changes needed — current state passes all gates '
            '(analyze + scoped tests).$implementSummary',
          );
          events.event(
            'CLOSE',
            prd: prdRef,
            issue: issue.number,
            detail: 'no-changes-pass',
          );
          print('  ${ansi.green('✓')} #${issue.number} already done → closed.');
          return true;
        }
        events.event(
          'RETRY',
          prd: prdRef,
          issue: issue.number,
          detail: 'no-changes attempt=$attempt/${config.maxAttempts}',
        );
        retry = _retryFeedback(
          analyzeOk: analyzeOk,
          testOk: testOk,
          noChanges: true,
        );
        print(
          '  ${ansi.red('No changes produced for #${issue.number} '
          '(attempt $attempt/${config.maxAttempts}).')}',
        );
        continue;
      }

      _phase(HarnessPhase.commit, '#${issue.number}');
      final committed = await git.commitAll(
        'feat(#${issue.number}): ${issue.title}\n\n'
        'Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>',
      );
      if (!committed) {
        events.event('COMMIT_FAIL', prd: prdRef, issue: issue.number);
        print('  ${ansi.red('commit failed for #${issue.number}')}');
        return false;
      }
      events.event('COMMIT', prd: prdRef, issue: issue.number);

      analyzeOk = await _gate(HarnessPhase.analyze, [
        'flutter',
        'analyze',
      ], _analyzeLog);
      testOk = await _scopedTestGate(baseline, issue.number);
      _logGates(prdRef, issue.number, analyzeOk: analyzeOk, testOk: testOk);

      if (analyzeOk && testOk) {
        await gh.closeIssue(
          issue.number,
          'Verified by AFK loop on branch `${await git.currentBranch()}`: '
          'analyze + scoped tests green.$implementSummary',
        );
        events.event('CLOSE', prd: prdRef, issue: issue.number, detail: 'pass');
        print('  ${ansi.green('✓ #${issue.number} PASS → closed.')}');
        return true;
      }

      events.event(
        'RETRY',
        prd: prdRef,
        issue: issue.number,
        detail:
            'attempt=$attempt/${config.maxAttempts} '
            'analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}',
      );
      retry = _retryFeedback(analyzeOk: analyzeOk, testOk: testOk);
      print(
        ansi.red(
          '  #${issue.number} attempt $attempt/${config.maxAttempts} FAILED '
          '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}).',
        ),
      );
    }

    // Every attempt failed — preserve the last try and hand off to a human.
    events.event(
      'FAIL',
      prd: prdRef,
      issue: issue.number,
      detail:
          'attempts=${config.maxAttempts} '
          'analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}',
    );
    await git.tagFail(issue.number);
    await git.resetHard(baseline);
    await gh.relabelForHuman(issue.number);
    await gh.commentOnIssue(
      issue.number,
      _failComment(
        issue.number,
        analyzeOk: analyzeOk,
        testOk: testOk,
        implementSummary: implementSummary,
      ),
    );
    print(
      ansi.red(
        '  #${issue.number} FAIL after ${config.maxAttempts} attempt(s) → '
        'tagged ralph-fail/${issue.number}, rolled back, '
        'relabeled ready-for-human.',
      ),
    );
    return false;
  }

  /// The `{{RETRY}}` block fed to the implementer on a re-attempt: which gate
  /// failed plus the tail of its log, so the agent fixes the real error instead
  /// of repeating the same attempt blind.
  String _retryFeedback({
    required bool analyzeOk,
    required bool testOk,
    bool noChanges = false,
  }) {
    final sections = <String>[];
    if (noChanges) {
      sections.add(
        'Your previous attempt produced NO file changes, yet the issue is not '
        'satisfied. You must actually edit the code this time.',
      );
    }
    if (!analyzeOk && File(_analyzeLog).existsSync()) {
      sections.add(
        '`fvm flutter analyze` FAILED:\n```\n${_tail(_analyzeLog, 40)}\n```',
      );
    }
    if (!testOk && File(_testLog).existsSync()) {
      sections.add(
        '`fvm flutter test` FAILED:\n```\n${_tail(_testLog, 40)}\n```',
      );
    }
    return '\n---\n## Previous attempt failed — fix these before finishing\n'
        'A prior automated attempt at this exact issue did not pass the gates. '
        'Treat the errors below as the source of truth and resolve every one '
        'of them.\n\n${sections.join('\n\n')}\n';
  }

  /// The per-issue test gate: runs only the tests the slice's diff scopes to
  /// (changed `*_test.dart` plus the mirror test of each changed `lib/` file),
  /// so a slice is never failed for a pre-existing red test it did not touch.
  /// The whole suite runs once at the PR gate. An empty scope passes — there is
  /// nothing the slice changed to test here; the PR gate is the backstop.
  Future<bool> _scopedTestGate(String baseline, int number) async {
    final scoped = scopedTestFiles(
      await git.changedFiles(baseline),
    ).where((path) => File(path).existsSync()).toList()..sort();
    if (scoped.isEmpty) {
      print(
        '  ${ansi.dim('No scoped tests for #$number '
        '→ test gate skipped (full suite runs at PR).')}',
      );
      return true;
    }
    print(
      '  ${ansi.dim('Scoped tests (${scoped.length}): ${scoped.join(', ')}')}',
    );
    return _gate(HarnessPhase.test, ['flutter', 'test', ...scoped], _testLog);
  }

  void _logGates(
    int? prd,
    int? issue, {
    required bool analyzeOk,
    required bool testOk,
  }) {
    events.event(
      'ANALYZE',
      prd: prd,
      issue: issue,
      detail: analyzeOk ? 'pass' : 'fail',
    );
    events.event(
      'TEST',
      prd: prd,
      issue: issue,
      detail: testOk ? 'pass' : 'fail',
    );
  }

  Future<bool> _gate(
    HarnessPhase phase,
    List<String> arguments,
    String logPath,
  ) async {
    _phase(phase);
    final result = await proc.run('fvm', arguments);
    File(logPath).writeAsStringSync('${result.stdout}${result.stderr}');
    final mark = result.ok ? ansi.green('✓ pass') : ansi.red('✗ fail');
    print('  $mark  fvm ${arguments.join(' ')}');
    return result.ok;
  }

  Future<void> _maybeOpenPr(int activeParent) async {
    await git.fetch(config.base);
    final ahead = await git.aheadOf(config.base);
    final openSubs = await _openSubsOf(activeParent);
    if (openSubs.isNotEmpty || ahead == 0) {
      final refs = openSubs.map((i) => '#${i.number}').join(', ');
      events.event(
        'PR_SKIP',
        prd: activeParent,
        detail: 'open_subs=${openSubs.length} commits_ahead=$ahead',
      );
      print(
        '  PRD #$activeParent not PR\'d '
        '(open_subs=${openSubs.length}${refs.isEmpty ? '' : ' [$refs]'}, '
        'commits_ahead=$ahead). Branch left for human.',
      );
      return;
    }

    _phase(HarnessPhase.pr, 'PRD #$activeParent');
    final title = await gh.issueTitle(activeParent);
    final canonical = await git.currentBranch();

    // A large PRD is opened as a chain of stacked PRs (one small diff each);
    // a small one stays a single PR exactly as before. Both leave HEAD on the
    // canonical branch so the holistic mechanical gate below sees the whole PRD.
    final chunks = await _chunkCommits();
    final List<_PrTarget> targets;
    if (chunks.length <= 1) {
      final url = await _openOnePr(activeParent, title, canonical);
      if (url == null) return;
      targets = [
        _PrTarget(url: url, baseRef: config.base, headBranch: canonical),
      ];
    } else {
      targets = await _openStackedPrs(activeParent, title, canonical, chunks);
      if (targets.isEmpty) return;
    }

    // Mechanical gate: the whole suite once over the canonical (full PRD) tree —
    // a red base (pre-existing failures) keeps every PR a draft for a human;
    // work is never discarded here, only the auto-ready signal is withheld.
    final analyzeOk = await _gate(HarnessPhase.analyze, [
      'flutter',
      'analyze',
    ], _analyzeLog);
    final testOk = await _gate(HarnessPhase.test, [
      'flutter',
      'test',
    ], _testLog);
    _logGates(activeParent, null, analyzeOk: analyzeOk, testOk: testOk);
    final suiteLine =
        'Full suite: analyze=${analyzeOk ? 'pass' : 'fail'} '
        'test=${testOk ? 'pass' : 'fail'}.';

    // Review each PR independently, scoped to its own diff: a single PR over the
    // whole PRD, or each stacked chunk over just its slice. Per-PR review keeps
    // a chunk PR carrying only the findings for the code it actually shows, and
    // lets each chunk go ready on its own (chunk 1 can merge while chunk 2 fails).
    final stacked = targets.length > 1;
    for (var i = 0; i < targets.length; i++) {
      final t = targets[i];
      if (stacked) await git.checkout(t.headBranch);
      _phase(
        HarnessPhase.review,
        stacked
            ? 'PR #$activeParent [${i + 1}/${targets.length}]'
            : 'PR #$activeParent',
      );
      final review = await _runWithApiRetry(
        () => claude.verify(
          prompts.prVerifier(
            activeParent,
            title,
            t.baseRef,
            repo: config.repo,
            prRef: t.url,
            chunkIndex: stacked ? i + 1 : null,
            chunkTotal: stacked ? targets.length : null,
          ),
        ),
        'PR review #$activeParent${stacked ? ' chunk ${i + 1}' : ''}',
      );
      _prdCostUsd += review.result?.costUsd ?? 0;
      _abortIfFatal(review, 'PR review #$activeParent');
      final pass = hasPassVerdict(review.transcript);
      events.event(
        'PR_REVIEW',
        prd: activeParent,
        detail: pass ? 'pass' : 'fail',
      );
      final reviewSummary = review.result == null
          ? ''
          : '\n\n_Review: ${review.result!.summary}._';
      final green = analyzeOk && testOk && pass;
      await gh.commentOnPr(
        t.url,
        '**AFK PR review (diff-verifier)**\n\n$suiteLine\n\n'
        '${reviewComment(review.transcript)}$reviewSummary'
        '\n\n_Total AFK spend for PRD #$activeParent: '
        '\$${_prdCostUsd.toStringAsFixed(4)}._',
      );
      if (green) {
        await gh.markPrReady(t.url);
        events.event('PR_READY', prd: activeParent, detail: 'url=${t.url}');
        print(
          '  ${ansi.green('✓ Full suite + review PASS → ${t.url} ready.')}',
        );
      } else {
        events.event(
          'PR_DRAFT',
          prd: activeParent,
          detail:
              'url=${t.url} analyze=${analyzeOk ? 1 : 0} '
              'test=${testOk ? 1 : 0} review=${pass ? 1 : 0}',
        );
        print(
          ansi.red(
            '  ✗ ${t.url} left as draft '
            '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0} '
            'review=${pass ? 1 : 0}).',
          ),
        );
      }
    }
    if (stacked) await git.checkout(canonical);
  }

  /// Pushes [branch] and opens the single whole-PRD draft PR (the unsplit
  /// path). Returns the PR url, or null if the push or create failed.
  Future<String?> _openOnePr(
    int activeParent,
    String title,
    String branch,
  ) async {
    if (!await git.pushBranch(branch)) {
      events.event('PUSH_FAIL', prd: activeParent, detail: 'branch=$branch');
      print('  ${ansi.red('push failed for $branch; leaving for human.')}');
      return null;
    }
    final prUrl = await gh.createDraftPr(
      base: config.base,
      head: branch,
      title: 'PRD #$activeParent: $title',
      body:
          'Implemented by the AFK loop for PRD #$activeParent.\n\n'
          'Each sub-issue passed analyze + tests before landing.\n\n'
          'AFK implement spend: \$${_prdCostUsd.toStringAsFixed(4)}.\n\n'
          'Closes #$activeParent\n\n'
          '🤖 Generated with [Claude Code](https://claude.com/claude-code)',
    );
    print('  PR: ${ansi.cyan(prUrl ?? '<none>')}');
    if (prUrl == null) {
      events.event('PR_OPEN_FAIL', prd: activeParent, detail: 'branch=$branch');
      return null;
    }
    events.event('PR_OPEN', prd: activeParent, detail: 'url=$prUrl');
    return prUrl;
  }

  /// Groups the PRD's landed commits (oldest→newest) into stacked-PR chunks,
  /// each at most `config.splitThreshold` changed lines, cutting only at commit
  /// boundaries. A single commit larger than the threshold becomes its own
  /// chunk. Per-commit sizes (`<sha>^..<sha>`) make the boundaries deterministic
  /// across re-runs, so the chunk branch names stay stable (idempotent). Returns
  /// one list of SHAs per chunk; length ≤ 1 means no split.
  Future<List<List<String>>> _chunkCommits() async {
    final shas = await git.commitLog(config.base);
    if (shas.length <= 1) return [shas];
    final chunks = <List<String>>[];
    var current = <String>[];
    var currentSize = 0;
    for (final sha in shas) {
      final size = await git.diffLineDelta('$sha^', sha);
      if (current.isNotEmpty && currentSize + size > config.splitThreshold) {
        chunks.add(current);
        current = [];
        currentSize = 0;
      }
      current.add(sha);
      currentSize += size;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  /// Opens the PRD as a chain of stacked draft PRs — chunk 1 onto `base`, each
  /// later chunk onto the previous chunk's branch, the last chunk reusing the
  /// canonical branch and carrying `Closes #parent`. Idempotent: a chunk whose
  /// branch already has an open PR is reused, so a re-run only fills the gaps.
  /// Ends on the canonical branch for the holistic gate. Returns one
  /// [_PrTarget] per chunk in stack order — carrying the chunk's diff base (the
  /// previous chunk's branch, or `config.base` for the first) and head branch so
  /// each PR can be reviewed over just its slice — or empty if the first chunk
  /// could not be pushed.
  Future<List<_PrTarget>> _openStackedPrs(
    int activeParent,
    String title,
    String canonical,
    List<List<String>> chunks,
  ) async {
    final slug = canonical.substring('$activeParent-'.length);
    final total = chunks.length;
    final targets = <_PrTarget>[];
    var base = config.base;
    for (var i = 0; i < total; i++) {
      final isLast = i == total - 1;
      final branch = isLast
          ? canonical
          : '$activeParent-chunk-${i + 1}-of-$total-$slug';

      final existing = await gh.openPrForBranch(branch);
      if (existing != null) {
        print('  PR ${i + 1}/$total exists: ${ansi.cyan(existing)}');
        targets.add(
          _PrTarget(url: existing, baseRef: base, headBranch: branch),
        );
        base = branch;
        continue;
      }

      if (!await git.checkoutNewAt(branch, chunks[i].last) ||
          !await git.pushBranch(branch)) {
        events.event('PUSH_FAIL', prd: activeParent, detail: 'branch=$branch');
        print('  ${ansi.red('cannot push $branch; stopping stack.')}');
        break;
      }

      final order = isLast
          ? 'Final chunk of the PRD stack.'
          : 'Stacked chunk ${i + 1}/$total — review and merge **after** '
                'chunk $i/$total is merged.';
      final prUrl = await gh.createDraftPr(
        base: base,
        head: branch,
        title: 'PRD #$activeParent [${i + 1}/$total]: $title',
        body:
            'Implemented by the AFK loop for PRD #$activeParent, '
            'split for easier review.\n\n'
            '$order\n\n'
            'AFK implement spend: \$${_prdCostUsd.toStringAsFixed(4)}.\n\n'
            '${isLast ? 'Closes #$activeParent\n\n' : ''}'
            '🤖 Generated with [Claude Code](https://claude.com/claude-code)',
      );
      print('  PR ${i + 1}/$total: ${ansi.cyan(prUrl ?? '<none>')}');
      if (prUrl == null) {
        events.event(
          'PR_OPEN_FAIL',
          prd: activeParent,
          detail: 'branch=$branch',
        );
        break;
      }
      events.event('PR_OPEN', prd: activeParent, detail: 'url=$prUrl');
      targets.add(_PrTarget(url: prUrl, baseRef: base, headBranch: branch));
      base = branch;
    }
    // Carving chunk branches moved HEAD; return to the canonical branch so the
    // holistic mechanical gate runs over the whole PRD tree.
    await git.checkout(canonical);
    return targets;
  }

  String _failComment(
    int number, {
    required bool analyzeOk,
    required bool testOk,
    String implementSummary = '',
  }) {
    final logs = [
      for (final path in [_analyzeLog, _testLog])
        if (File(path).existsSync()) '==> $path <==\n${_tail(path, 20)}',
    ].join('\n\n');
    return 'AFK verify FAILED '
        '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}).'
        '$implementSummary\n\n'
        'Failed attempt preserved at tag `ralph-fail/$number` '
        '(recover with `git checkout ralph-fail/$number`).\n\n'
        '**Logs**\n```\n$logs\n```';
  }

  String _tail(String path, int count) {
    final lines = File(path).readAsLinesSync();
    final start = lines.length > count ? lines.length - count : 0;
    return lines.sublist(start).join('\n');
  }
}

/// One opened PR to review: its [url], the branch its diff is taken against
/// ([baseRef] → `origin/<baseRef>..HEAD`), and the [headBranch] to check out so
/// that range resolves to just this PR's slice. For a single PR [baseRef] is
/// `config.base` and [headBranch] the canonical branch; for a stacked chunk
/// they are the previous chunk's branch (or `config.base` for the first) and
/// the chunk branch.
class _PrTarget {
  _PrTarget({
    required this.url,
    required this.baseRef,
    required this.headBranch,
  });

  final String url;
  final String baseRef;
  final String headBranch;
}
