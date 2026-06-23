import 'dart:async';
import 'dart:io';

import 'ansi.dart';
import 'call_log.dart';
import 'ci_status.dart';
import 'claude.dart';
import 'config.dart';
import 'context_budget.dart';
import 'event_log.dart';
import 'git.dart';
import 'github.dart';
import 'issue.dart';
import 'model_ladder.dart';
import 'phase.dart';
import 'pr_comments.dart';
import 'proc.dart';
import 'prompts.dart';
import 'retry_feedback.dart';
import 'secret_scan.dart';
import 'slice_scope.dart';
import 'test_scope.dart';
import 'trace.dart';
import 'verdict.dart';

part 'ci_watcher.dart';
part 'slice_runner.dart';
part 'worker_pool.dart';

/// Per-issue gate log paths, keyed by number so concurrent slices never clobber
/// a shared file.
String _analyzeLogFor(int number) => '/tmp/ralph-$number-analyze.log';
String _testLogFor(int number) => '/tmp/ralph-$number-test.log';

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
    TraceStore? traces,
    CallLog? calls,
    Ansi? ansi,
    this.apiRetryBackoff = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 45),
    ],
  }) : events = events ?? EventLog(),
       traces = traces ?? TraceStore(),
       calls = calls ?? CallLog(),
       ansi = ansi ?? Ansi.forStdout();

  final Config config;
  final GhCli gh;
  final GitOps git;
  final ClaudeRunner claude;
  final ProcessRunner proc;
  final PromptLibrary prompts;

  /// Target-repo `.claude/rules/*.md` flattened into the implementer's
  /// `--append-system-prompt`; `''` when the target ships none.
  final String rulesSystemPrompt;

  final EventLog events;

  /// Cross-run friction log; [run] prints a [summarize] report at the end.
  final TraceStore traces;

  /// Durable per-call cost ledger ([_recordCall] appends, [_printCostReport]
  /// summarizes this run).
  final CallLog calls;

  final List<CallRecord> _runCalls = [];

  final Ansi ansi;

  /// Riskiest lane among a PRD's slices — one high-risk slice raises the whole
  /// PR's review bar in [_maybeOpenPr].
  final Map<int, RiskLane> _prdLane = {};

  /// Backoff per retry of a *transient* `claude` API failure; length is the
  /// retry cap. Injectable so tests don't sleep.
  final List<Duration> apiRetryBackoff;

  /// `claude` spend for the PRD being drained; reset when a new PRD starts.
  double _prdCostUsd = 0;

  /// Issue numbers already consumed this run. GitHub's issue list lags a write,
  /// so this guard keeps a just-handled issue from being picked up twice.
  final Set<int> _handled = {};

  /// Parallel mode: issues whose slice passed this run. A pass is not closed
  /// until the merge phase, so dependents read readiness from here, not GitHub.
  final Set<int> _passedThisRun = {};

  /// Parallel mode: per-PRD `claude` spend across worktrees, copied into
  /// [_prdCostUsd] before each PRD's PR opens.
  final Map<int, double> _prdCostAccum = {};

  /// Parallel mode: each slice's terminal outcome, cherry-picked onto its PRD
  /// branch by [_mergeAndPrAll].
  final Map<int, _WorkerOutcome> _workerOutcomes = {};

  /// Parallel mode: each passed slice's exact changed-file set, captured at
  /// pass to sharpen `implicitBlockers` from prediction to ground truth.
  final Map<int, Set<String>> _sliceScope = {};

  /// Parallel mode: the file-overlap blockers [_nextReady] chose for each slice,
  /// read by [_runIssueInWorktree] to pick its merge base. Never overwritten.
  final Map<int, Set<int>> _implicitBlockers = {};

  /// Parallel mode: live worker registry for the dashboard.
  final Map<int, _Worker> _workers = {};

  /// Parallel mode: set when an in-flight worker hits a pool-stopping condition
  /// (usage limit → resumable, auth/billing → hard). The scheduler then drains,
  /// [_checkpointAndCleanup]s, and [run] rethrows.
  ClaudeAbort? _hardAbort;

  /// Parallel-mode dashboard state; [_dashboardLines] is the last block height
  /// so the next render can overwrite it. Null timer when stdout is not a tty.
  Timer? _dashboardTimer;
  int _dashboardLines = 0;

  void _phase(HarnessPhase phase, [String? detail]) =>
      print(phase.marker(ansi, detail));

  /// Aborts the whole loop on an unrecoverable `claude` condition — every later
  /// call would fail the same way. A rate limit is resumable (checkpoint and
  /// exit for a re-run); an exhausted-transient or auth/billing failure is hard.
  void _abortIfFatal(ClaudeRun run, String context) {
    if (run.rateLimited != null) {
      throw ClaudeAbort(
        '$context — ${run.rateLimited!.summary}',
        resumable: true,
      );
    }
    final fatal = run.fatalError ?? run.transientApiError;
    if (fatal != null) throw ClaudeAbort('$context — $fatal');
  }

  /// Runs a `claude` call, retrying a *transient* API failure with
  /// [apiRetryBackoff]. A transient run that survives the last retry is returned
  /// for the caller's [_abortIfFatal] to abort on.
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

  /// Prints the cross-run friction report at the end of a run. Advisory only;
  /// silent when nothing has been recorded.
  void _printFrictionReport() {
    final report = summarize(traces.readAll());
    if (report.isEmpty) return;
    print('');
    print(ansi.dim(report.render()));
  }

  /// Records one completed `claude` call to the cost ledger and its in-memory
  /// mirror. [model] is null for an agent-pinned call (`classify`/`prReview`).
  void _recordCall(
    CallPhase phase,
    ClaudeRun run, {
    int? issue,
    int? prd,
    String? model,
    int? attempt,
  }) {
    final result = run.result;
    final record = CallRecord(
      ts: DateTime.now().toIso8601String(),
      phase: phase,
      issue: issue,
      prd: prd,
      model: model,
      attempt: attempt,
      costUsd: result?.costUsd ?? 0,
      numTurns: result?.numTurns ?? 0,
      durationMs: result?.durationMs ?? 0,
      ctxFreePct: run.contextFreePct,
      outcome: result?.subtype,
      denials: result?.permissionDenials ?? 0,
    );
    _runCalls.add(record);
    calls.append(record);
  }

  /// Prints this run's spend split by phase and model. Silent when no `claude`
  /// call was made.
  void _printCostReport() {
    final report = summarizeCalls(_runCalls);
    if (report.isEmpty) return;
    print('');
    print(ansi.dim(report.render()));
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
      if (config.concurrency > 1) {
        processed = await _drainParallel(0);
        capHit = config.iterations != null && processed >= config.iterations!;
      } else {
        while (true) {
          final activeParent = await _selectActivePrd();
          if (activeParent == null) break;
          processed += await _drainPrd(activeParent, processed);
          if (config.iterations != null && processed >= config.iterations!) {
            capHit = true;
            break;
          }
        }
      }
      if (!capHit) {
        // Ship any PRD whose work finished but never got a PR (its last failed
        // sub was resolved out-of-band, so it never re-entered selection).
        await _shipStrandedPrds();
        print('No processable ready-for-agent issues remain. Done.');
      }
      _printFrictionReport();
      events.event('DONE');
      return 0;
    } on ClaudeAbort catch (e) {
      events.event(
        'ABORT',
        detail: '${e.resumable ? 'resumable ' : ''}${e.message}',
      );
      if (e.resumable) {
        // Usage limit: completed slices are checkpointed, the rest stay
        // `ready-for-agent`. Exit EX_TEMPFAIL (75) so a wrapper re-runs once the
        // window reopens and the idempotent harness resumes.
        stderr.writeln(ansi.yellow('⏸ Usage limit reached — ${e.message}'));
        stderr.writeln(
          'Completed work was checkpointed; remaining issues stay '
          'ready-for-agent. Re-run when the limit window resets to resume.',
        );
        return 75;
      }
      stderr.writeln(ansi.red('✗ Fatal: ${e.message}'));
      stderr.writeln(
        'claude cannot continue — aborting the AFK loop. Completed slices were '
        'checkpointed; in-flight work is left for a human.',
      );
      return 2;
    } finally {
      _printCostReport();
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

  /// `--review-pr`: review an existing PR instead of implementing. Runs the full
  /// suite + diff-verifier over its diff, comments the verdict, and marks it
  /// ready only when both are green. Returns 0 on a green verdict.
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
    ], _analyzeLogFor(info.number));
    final testOk = await _gate(HarnessPhase.test, [
      'flutter',
      'test',
    ], _testLogFor(info.number));
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
    _recordCall(CallPhase.prReview, review, prd: info.number);
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
      '${manualSection(verdict)}'
      '${structuralSection(verdict)}'
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

  /// Ships any PRD branch whose work is done but never got a PR (a failed sub
  /// resolved out-of-band, so [_drainPrd] never re-ran). Idempotent — see
  /// [_strandedPrds] for the skip conditions.
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
      // Skip leftover stacked-PR chunk branches: they hold only part of a PRD.
      if (chunkBranch.hasMatch(branch)) continue;
      final match = RegExp(r'^(\d+)-').firstMatch(branch);
      if (match == null) continue;
      branchByParent[int.parse(match.group(1)!)] = branch;
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

  /// The PRD's still-open managed subs (`ready-for-agent`/`ready-for-human`).
  /// Excludes [activeParent] itself: a PRD-of-one is its own parent, so without
  /// the guard a lagging list of the just-closed parent would block its own PR.
  Future<List<Issue>> _openSubsOf(int activeParent) async {
    final byLabel = await Future.wait([
      for (final label in const ['ready-for-agent', 'ready-for-human'])
        gh.issuesWithLabel(label, 'open'),
    ]);
    final byNumber = <int, Issue>{};
    for (final issue in byLabel.expand((issues) => issues)) {
      if (issue.number != activeParent &&
          parentOf(issue.body, issue.number) == activeParent) {
        byNumber[issue.number] = issue;
      }
    }
    return byNumber.values.toList();
  }

  /// Cross-slice context for the implementer — the parent PRD's title+body and a
  /// roster of in-flight siblings — so it can reconcile shared interfaces up
  /// front. Empty for a PRD-of-one (no [parent]).
  Future<({String prdContext, String sliceMap})> _coherenceContext(
    int? parent,
    int self,
  ) async {
    if (parent == null) return (prdContext: '', sliceMap: '');
    final title = await gh.issueTitle(parent);
    final body = await gh.issueBody(parent);
    final prdContext = StringBuffer('## PRD #$parent: $title');
    if (body.isNotEmpty) prdContext.write('\n\n${clampPrdBody(body, parent)}');
    final siblings =
        (await _openSubsOf(parent)).where((s) => s.number != self).toList()
          ..sort((a, b) => a.number.compareTo(b.number));
    final sliceMap = [
      for (final s in siblings)
        '- #${s.number} ${s.title}'
            '${s.labels.contains('ready-for-human') ? ' (needs human)' : ''}',
    ].join('\n');
    return (prdContext: prdContext.toString(), sliceMap: sliceMap);
  }

  /// Leaves the PR-skip reason as a durable comment on the PRD issue. Idempotent:
  /// a hidden signature of the cause (open subs + commits ahead) blocks a repost
  /// until the cause changes.
  Future<void> _commentPrSkip(
    int prd,
    List<Issue> openSubs,
    int ahead,
    String text,
  ) async {
    final signature =
        '<!-- dartralph:pr-skip '
        'subs=${openSubs.map((i) => i.number).join(',')} ahead=$ahead -->';
    final existing = await gh.issueComments(prd);
    if (existing.contains(signature)) return;
    await gh.commentOnIssue(
      prd,
      '$signature\n\n🚧 **No PR opened yet.**\n\n$text',
    );
  }

  Future<void> _maybeOpenPr(int activeParent) async {
    final analyzeLog = _analyzeLogFor(activeParent);
    final testLog = _testLogFor(activeParent);
    await git.fetch(config.base);
    final ahead = await git.aheadOf(config.base);
    final openSubs = await _openSubsOf(activeParent);
    if (openSubs.isNotEmpty || ahead == 0) {
      final branch = await git.currentBranch();
      final explain = prSkipExplanation(
        prd: activeParent,
        ahead: ahead,
        base: config.base,
        branch: branch,
        openSubs: [
          for (final i in openSubs)
            (
              number: i.number,
              needsHuman: i.labels.contains('ready-for-human'),
            ),
        ],
      );
      events.event(
        'PR_SKIP',
        prd: activeParent,
        detail:
            'open_subs=${openSubs.length} commits_ahead=$ahead '
            'needs_human=${explain.needsHuman}',
      );
      print('  ${explain.text.replaceAll('\n', '\n  ')}');
      if (explain.needsHuman) {
        await _commentPrSkip(activeParent, openSubs, ahead, explain.text);
      }
      return;
    }

    _phase(HarnessPhase.pr, 'PRD #$activeParent');
    final title = await gh.issueTitle(activeParent);
    final canonical = await git.currentBranch();
    await gh.closeChunkPrs(activeParent);

    // The whole suite once over the full PRD tree. A red base keeps the PRD a
    // draft for a human — work is never discarded, only the ready signal held.
    var analyzeOk = await _gate(HarnessPhase.analyze, [
      'flutter',
      'analyze',
    ], analyzeLog);
    var testOk = await _gate(HarnessPhase.test, ['flutter', 'test'], testLog);
    _logGates(activeParent, null, analyzeOk: analyzeOk, testOk: testOk);

    // One holistic review over the whole PRD diff (origin/<base>..HEAD). The
    // reviewer reads the local commit range, so no PR need exist yet.
    Future<ClaudeRun> runReview() async {
      _phase(HarnessPhase.review, 'PR #$activeParent');
      final r = await _runWithApiRetry(
        () => claude.verify(
          prompts.prVerifier(
            activeParent,
            title,
            config.base,
            repo: config.repo,
            prRef: canonical,
            lane: _prdLane[activeParent],
          ),
        ),
        'PR review #$activeParent',
      );
      _prdCostUsd += r.result?.costUsd ?? 0;
      _recordCall(CallPhase.prReview, r, prd: activeParent);
      _abortIfFatal(r, 'PR review #$activeParent');
      return r;
    }

    var review = await runReview();
    var pass = hasPassVerdict(review.transcript);
    events.event(
      'PR_REVIEW',
      prd: activeParent,
      detail: pass ? 'pass' : 'fail',
    );

    // Gates green but reviewer FAILED → feed the blocking findings to a fixer,
    // commit, re-gate, re-review, up to config.maxReviewFixes rounds. A red
    // build or a no-op fix stops the loop and lets the standing verdict decide.
    for (
      var round = 1;
      !pass && analyzeOk && testOk && round <= config.maxReviewFixes;
      round++
    ) {
      _phase(
        HarnessPhase.implement,
        'PRD #$activeParent review fix $round/${config.maxReviewFixes}',
      );
      events.event(
        'REVIEW_FIX',
        prd: activeParent,
        detail: 'round=$round/${config.maxReviewFixes}',
      );
      print(
        '  ${ansi.dim('↻ review fix $round/${config.maxReviewFixes} for '
        'PRD #$activeParent — feeding the blocking findings back.')}',
      );
      final fix = await _runWithApiRetry(
        () => claude.implement(
          model: config.model,
          prompt: prompts.fixer(
            activeParent,
            title,
            config.base,
            findings: reviewComment(review.transcript),
          ),
          systemAppend: rulesSystemPrompt,
        ),
        'Review fix #$activeParent',
      );
      _prdCostUsd += fix.result?.costUsd ?? 0;
      _recordCall(
        CallPhase.reviewFix,
        fix,
        prd: activeParent,
        model: config.model,
      );
      _abortIfFatal(fix, 'Review fix #$activeParent');

      if (!await git.hasDrift()) {
        print(
          '  ${ansi.dim('Review fix $round produced no changes — leaving the '
          'standing verdict to decide.')}',
        );
        break;
      }
      _phase(HarnessPhase.commit, 'PRD #$activeParent fix $round');
      await git.stageAll();
      final fixLeaks = scanSecrets(await git.stagedDiff());
      if (fixLeaks.isNotEmpty) {
        events.event(
          'SECRET_BLOCK',
          prd: activeParent,
          detail: 'review-fix round=$round ${fixLeaks.join('; ')}',
        );
        await git.resetHard('HEAD');
        print(
          ansi.red(
            '  Review fix $round added an apparent secret '
            '(${fixLeaks.join('; ')}) — dropped; leaving the PR for a human.',
          ),
        );
        break;
      }
      await git.commitStaged(
        'fix(#$activeParent): address review findings (round $round)\n\n'
        'Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>',
      );
      analyzeOk = await _gate(HarnessPhase.analyze, [
        'flutter',
        'analyze',
      ], analyzeLog);
      testOk = await _gate(HarnessPhase.test, ['flutter', 'test'], testLog);
      _logGates(activeParent, null, analyzeOk: analyzeOk, testOk: testOk);
      review = await runReview();
      pass = hasPassVerdict(review.transcript);
      events.event(
        'PR_REVIEW',
        prd: activeParent,
        detail: pass ? 'pass' : 'fail',
      );
    }

    final suiteLine =
        'Full suite: analyze=${analyzeOk ? 'pass' : 'fail'} '
        'test=${testOk ? 'pass' : 'fail'}.';
    final reviewSummary = review.result == null
        ? ''
        : '\n\n_Review: ${review.result!.summary}._';
    final reviewBody =
        '**AFK PR review (diff-verifier)**\n\n$suiteLine\n\n'
        '${reviewComment(review.transcript)}$reviewSummary'
        '${manualSection(review.transcript)}'
        '${structuralSection(review.transcript)}'
        '\n\n_Total AFK spend for PRD #$activeParent: '
        '\$${_prdCostUsd.toStringAsFixed(4)}._';
    final green = analyzeOk && testOk && pass;

    final url = await _openOnePr(activeParent, title, canonical);
    if (url == null) return;
    await gh.commentOnPr(url, reviewBody);

    if (green) {
      // Local gates + review green. Follow the PR's remote CI to a conclusion
      // before marking ready — GitHub Actions can fail what `fvm flutter` here
      // never runs (a different OS, golden tests, codegen). `--watch-ci=0` and
      // a repo with no checks both skip the wait.
      if (!config.watchCi) {
        await gh.markPrReady(url);
        events.event('PR_READY', prd: activeParent, detail: 'url=$url ci=off');
        print('  ${ansi.green('✓ Full suite + review PASS → $url ready.')}');
        return;
      }
      final outcome = await _watchCi(
        activeParent,
        title,
        url,
        canonical,
        analyzeLog: analyzeLog,
        testLog: testLog,
      );
      switch (outcome) {
        case _CiOutcome.ready:
        case _CiOutcome.noCi:
          await gh.markPrReady(url);
          final note = outcome == _CiOutcome.noCi
              ? 'no remote CI — ready off local verdict'
              : 'remote CI green';
          events.event(
            'PR_READY',
            prd: activeParent,
            detail: 'url=$url ci=${outcome.name}',
          );
          print(
            '  ${ansi.green('✓ Full suite + review PASS, $note → $url '
            'ready.')}',
          );
          return;
        case _CiOutcome.failed:
        case _CiOutcome.timedOut:
          traces.append(
            TraceRecord(
              ts: DateTime.now().toIso8601String(),
              prd: activeParent,
              lane: _prdLane[activeParent] ?? RiskLane.normal,
              outcome: 'draft',
              attempts: 1,
              frictions: const [FrictionKind.ciFail],
            ),
          );
          await gh.markPrDraft(url);
          events.event(
            'PR_DRAFT',
            prd: activeParent,
            detail: 'url=$url ci=${outcome.name}',
          );
          print(
            ansi.red(
              '  ✗ $url left as draft '
              '(local gates + review green, but remote CI '
              '${outcome == _CiOutcome.timedOut ? 'did not settle in time' : 'stayed red'}).',
            ),
          );
          return;
      }
    }

    // Red gate or rejected review: demote to draft for a human. Nothing rolled
    // back.
    if (!pass) {
      traces.append(
        TraceRecord(
          ts: DateTime.now().toIso8601String(),
          prd: activeParent,
          lane: _prdLane[activeParent] ?? RiskLane.normal,
          outcome: 'draft',
          attempts: 1,
          frictions: const [FrictionKind.reviewerReject],
        ),
      );
    }
    await gh.markPrDraft(url);
    events.event(
      'PR_DRAFT',
      prd: activeParent,
      detail:
          'url=$url analyze=${analyzeOk ? 1 : 0} '
          'test=${testOk ? 1 : 0} review=${pass ? 1 : 0}',
    );
    print(
      ansi.red(
        '  ✗ $url left as draft '
        '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0} '
        'review=${pass ? 1 : 0}).',
      ),
    );
  }

  /// Watches the draft PR's remote CI to a conclusion, auto-fixing failures up
  /// to [Config.maxCiFixes] rounds. Polling backs off (30s → 60s → 120s via
  /// [ciPollInterval]) with a 60s grace before trusting an empty rollup. Returns
  /// [_CiOutcome.ready] (green, not in conflict), [_CiOutcome.noCi] (no checks
  /// after the grace), [_CiOutcome.failed] (red past the budget / a fix could
  /// not land / branch conflicts), or [_CiOutcome.timedOut].
  Future<_CiOutcome> _watchCi(
    int activeParent,
    String title,
    String url,
    String branch, {
    required String analyzeLog,
    required String testLog,
  }) async {
    _phase(HarnessPhase.pr, 'CI watch — PR #$activeParent');
    final start = DateTime.now();
    final deadline = start.add(config.ciTimeout);
    // A PR opened seconds ago may report no checks yet; only conclude "no CI"
    // after this grace. A fix push resets it (the new run must register).
    var graceUntil = start.add(const Duration(seconds: 60));
    var fixes = 0;

    while (true) {
      final status = await gh.prCiStatus(url);
      switch (status.state) {
        case CiState.passing:
          // A branch that conflicts with base cannot merge regardless of CI.
          if (status.mergeable == false) {
            events.event('CI_CONFLICT', prd: activeParent, detail: 'url=$url');
            print(
              ansi.red(
                '  remote CI passed but the branch conflicts with '
                '${config.base} — leaving draft for a human.',
              ),
            );
            return _CiOutcome.failed;
          }
          events.event('CI_PASS', prd: activeParent, detail: 'url=$url');
          print('  ${ansi.green('✓ remote CI passed.')}');
          return _CiOutcome.ready;

        case CiState.none:
          if (DateTime.now().isAfter(graceUntil)) {
            events.event('CI_NONE', prd: activeParent, detail: 'url=$url');
            print(ansi.dim('  No remote CI on this PR — skipping the watch.'));
            return _CiOutcome.noCi;
          }

        case CiState.pending:
          break;

        case CiState.failing:
          if (fixes >= config.maxCiFixes) {
            events.event(
              'CI_FAIL',
              prd: activeParent,
              detail: 'url=$url fixes=$fixes/${config.maxCiFixes} exhausted',
            );
            print(
              ansi.red(
                '  ✗ remote CI still failing after ${config.maxCiFixes} '
                'fix round(s).',
              ),
            );
            await _commentCiHandoff(
              url,
              'remote CI still failed after ${config.maxCiFixes} auto-fix '
              'round(s)',
            );
            return _CiOutcome.failed;
          }
          fixes++;
          final fixed = await _runCiFix(
            activeParent,
            title,
            url,
            branch,
            status.failedRunIds,
            fixes,
            analyzeLog: analyzeLog,
            testLog: testLog,
          );
          if (!fixed) {
            await _commentCiHandoff(
              url,
              'a CI auto-fix could not be applied cleanly (no change, a local '
              'gate regression, an apparent secret, or a push failure)',
            );
            return _CiOutcome.failed;
          }
          // Reset the grace so the next poll waits out the new queueing run.
          graceUntil = DateTime.now().add(const Duration(seconds: 60));
      }

      if (DateTime.now().isAfter(deadline)) {
        events.event(
          'CI_TIMEOUT',
          prd: activeParent,
          detail: 'url=$url after=${config.ciTimeout.inMinutes}m',
        );
        print(
          ansi.red(
            '  ✗ remote CI did not settle within ${config.ciTimeout.inMinutes}m '
            '— leaving draft for a human.',
          ),
        );
        await _commentCiHandoff(
          url,
          'remote CI did not settle within ${config.ciTimeout.inMinutes} '
          'minutes',
        );
        return _CiOutcome.timedOut;
      }
      await Future<void>.delayed(
        ciPollInterval(DateTime.now().difference(start)),
      );
    }
  }

  /// Pushes [branch] and opens the whole-PRD PR, reusing one that already tracks
  /// [branch] so a re-run updates in place. Returns the url, or null on failure.
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
    final existing = await gh.openPrForBranch(branch);
    if (existing != null) {
      print('  PR exists: ${ansi.cyan(existing)} ${ansi.dim('(updated)')}');
      events.event('PR_OPEN', prd: activeParent, detail: 'url=$existing');
      return existing;
    }
    final prUrl = await gh.createDraftPr(
      base: config.base,
      head: branch,
      title: 'PRD #$activeParent: $title',
      body:
          'Implemented by the AFK loop for PRD #$activeParent.\n\n'
          'Each sub-issue passed analyze + tests before landing.\n\n'
          'AFK implement spend: \$${_prdCostUsd.toStringAsFixed(4)}.'
          '${_gateEvidence(activeParent)}\n\n'
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

  /// Reads the PRD's gate log tails and renders them via [gateEvidence] for the
  /// PR description.
  String _gateEvidence(int parent) => gateEvidence([
    for (final (label, path) in [
      ('analyze', _analyzeLogFor(parent)),
      ('test', _testLogFor(parent)),
    ])
      if (File(path).existsSync()) (label, _tail(path, 15)),
  ]);

  /// Reads the failing gate log tails and renders the handoff via [failComment].
  String _failComment(
    int number, {
    required bool analyzeOk,
    required bool testOk,
    required String analyzeLog,
    required String testLog,
    String implementSummary = '',
    bool contextStarved = false,
  }) {
    final logs = [
      for (final path in [analyzeLog, testLog])
        if (File(path).existsSync()) '==> $path <==\n${_tail(path, 20)}',
    ].join('\n\n');
    return failComment(
      number,
      analyzeOk: analyzeOk,
      testOk: testOk,
      logs: logs,
      implementSummary: implementSummary,
      contextStarved: contextStarved,
    );
  }

  String _tail(String path, int count) {
    final lines = File(path).readAsLinesSync();
    final start = lines.length > count ? lines.length - count : 0;
    return lines.sublist(start).join('\n');
  }
}
