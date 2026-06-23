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
import 'test_scope.dart';
import 'trace.dart';
import 'verdict.dart';

part 'ci_watcher.dart';
part 'slice_runner.dart';
part 'worker_pool.dart';

/// Per-issue gate log paths. Keyed by issue/PRD number so two slices gating
/// concurrently (parallel pool) never clobber each other's log — and so a
/// cross-suite parallel `dart test` no longer reads a half-written shared file
/// (the historical flaky source). Sequential runs key by the same number, so
/// behavior is unchanged at N=1.
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

  /// Target-repo `.claude/rules/*.md`, flattened into one blob and injected into
  /// the implementer's system prompt via `--append-system-prompt`. Loaded once
  /// at startup; `''` when the target ships no root-level rules. See
  /// `loadRulesSystemPrompt` (`rules.dart`).
  final String rulesSystemPrompt;

  final EventLog events;

  /// Cross-run friction log. Each terminal slice/PR outcome appends one
  /// [TraceRecord]; [run] prints a [summarize] report at the end so repeated
  /// friction across runs surfaces as advisory proposals.
  final TraceStore traces;

  /// Durable per-call cost ledger. Every completed `claude` call appends one
  /// [CallRecord] (phase, model, cost/turns/duration) via [_recordCall], so the
  /// spend that the human transcript prints and forgets is recoverable for
  /// later analysis. [_printCostReport] summarizes this run's calls at the end.
  final CallLog calls;

  /// This run's [CallRecord]s in order, mirrored in memory so [_printCostReport]
  /// scopes to the current run without re-reading the cross-run [calls] file.
  final List<CallRecord> _runCalls = [];

  final Ansi ansi;

  /// Highest (riskiest) lane seen among a PRD's slices, keyed by PRD parent
  /// number. Feeds the PR reviewer's bar in [_maybeOpenPr]. A PRD takes the max
  /// of its slices: one high-risk slice raises the whole PR's review bar.
  final Map<int, RiskLane> _prdLane = {};

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

  /// Parallel mode only (`concurrency > 1`). Issue numbers whose slice passed
  /// its gates *this run*. A passed slice is not closed until the merge phase
  /// (its commit must first land on the PRD branch), so its blocker dependents
  /// cannot rely on GitHub state alone to know it is done — this set is the
  /// in-run half of the DAG-readiness check in [_nextReady].
  final Set<int> _passedThisRun = {};

  /// Parallel mode only. Per-PRD `claude` spend, summed across that PRD's slices
  /// run in their own worktrees. The sequential [_prdCostUsd] cannot be shared
  /// across concurrent PRDs, so the pool accumulates here and copies the total
  /// into [_prdCostUsd] just before each PRD's PR is opened.
  final Map<int, double> _prdCostAccum = {};

  /// Parallel mode only. Each slice's terminal outcome, keyed by issue number —
  /// what the merge phase ([_mergeAndPrAll]) cherry-picks onto each PRD branch.
  final Map<int, _WorkerOutcome> _workerOutcomes = {};

  /// Parallel mode only. Live worker registry for the dashboard.
  final Map<int, _Worker> _workers = {};

  /// Parallel mode only. When a `claude` run reports a rate limit, the scheduler
  /// stops launching new slices until this instant; in-flight workers ride their
  /// own [_runWithApiRetry] backoff. Null when not paused.
  DateTime? _rateLimitPausedUntil;

  /// Parallel mode only. Set when an in-flight worker hits an unrecoverable
  /// condition (auth/billing/exhausted-transient). The scheduler stops launching
  /// new work, lets in-flight workers drain, then rethrows so [run] aborts.
  ClaudeAbort? _hardAbort;

  /// Parallel mode only. Drives the live worker dashboard; null when not running
  /// or when stdout is not a terminal. [_dashboardLines] is the height of the
  /// block last drawn, so the next render can move the cursor up to overwrite it.
  Timer? _dashboardTimer;
  int _dashboardLines = 0;

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

  /// Aggregates the cross-run trace log into a [FrictionReport] and prints it at
  /// the end of an AFK run. Advisory only: it surfaces repeated friction so a
  /// human can act, and never changes the loop's behavior. Silent when nothing
  /// has been recorded yet.
  void _printFrictionReport() {
    final report = summarize(traces.readAll());
    if (report.isEmpty) return;
    print('');
    print(ansi.dim(report.render()));
  }

  /// Records one completed `claude` call's telemetry to the durable cost ledger
  /// (and the in-memory mirror the end-of-run report reads). Purely additive —
  /// it never touches the `_prdCostUsd` accounting the PR comments report, so
  /// the ledger and the human-facing spend number are sourced from the same
  /// `result` event and cannot drift. [model] is null for an agent-pinned call
  /// (`classify`/`prReview`) whose model the harness does not pass.
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

  /// Prints this run's cost report — the spend split by phase and by model plus
  /// the implement lane-tiering saving — at the end of a run. Advisory and
  /// observability only: it never changes the loop's behavior. Silent when no
  /// `claude` call was made (e.g. an empty queue).
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
        // Parallel path: a bounded worker pool drains the whole ready queue at
        // the sub-issue grain (DAG-scheduled by `## Blocked by`), each slice in
        // its own worktree, then merges per-PRD and opens one PR per PRD.
        processed = await _drainParallel(0);
        capHit = config.iterations != null && processed >= config.iterations!;
      } else {
        // Sequential path (N=1) — unchanged, one PRD then one sub at a time.
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
        // Queue is drained. A PRD whose last failed sub was resolved (closed in
        // a later run or by a human) never re-enters selection, so its branch
        // would otherwise sit un-PR'd forever. Sweep for those and ship them.
        await _shipStrandedPrds();
        print('No processable ready-for-agent issues remain. Done.');
      }
      _printFrictionReport();
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
    } finally {
      // Covers every exit (review-PR, single-issue, full drain, and abort): the
      // spend summary prints once no matter which `return` fired. Silent when no
      // `claude` call was made this run.
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
      // Skip leftover stacked-PR chunk branches from an older split run: they
      // hold only part of the PRD, so PR'ing one with `Closes #parent` would
      // close the PRD on a partial diff. The canonical branch ships the whole.
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

  /// Cross-slice context for the implementer: the parent PRD's title+body plus a
  /// roster of the sibling slices still in flight. Empty for a PRD-of-one (no
  /// [parent]), so a standalone issue gets no noise. This is what lets the
  /// implementer reconcile shared interfaces up front instead of leaving
  /// cross-slice integration gaps for the single end-of-PRD review to drain.
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

  Future<void> _maybeOpenPr(int activeParent) async {
    final analyzeLog = _analyzeLogFor(activeParent);
    final testLog = _testLogFor(activeParent);
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
    // The harness no longer splits PRDs; close any leftover stacked-PR chunk
    // PRs from an older split run so the single PR does not sit beside orphans.
    await gh.closeChunkPrs(activeParent);

    // Mechanical gate: the whole suite once over the canonical (full PRD) tree —
    // a red base (pre-existing failures) keeps the PRD a draft for a human;
    // work is never discarded here, only the auto-ready signal is withheld.
    var analyzeOk = await _gate(HarnessPhase.analyze, [
      'flutter',
      'analyze',
    ], analyzeLog);
    var testOk = await _gate(HarnessPhase.test, ['flutter', 'test'], testLog);
    _logGates(activeParent, null, analyzeOk: analyzeOk, testOk: testOk);

    // One holistic review over the whole PRD diff (origin/<base>..HEAD on the
    // canonical branch). The reviewer reads the local commit range, so no PR
    // need exist yet, and a single review covers the whole PRD.
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

    // Auto-fix loop: gates green but the reviewer FAILED → feed the blocking
    // findings to a PRD-level fixer, commit, re-gate, re-review — up to
    // config.maxReviewFixes rounds. Only when the gates are green: a red build
    // is a human's problem, never something we keep auto-patching. A fixer that
    // produces no drift has nothing more to offer, so we stop and let the
    // standing verdict decide the PR.
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

    // One PR per PRD on the canonical branch. A re-run reuses the existing PR
    // (push updates it in place) instead of opening a new one.
    final url = await _openOnePr(activeParent, title, canonical);
    if (url == null) return;
    await gh.commentOnPr(url, reviewBody);

    if (green) {
      // The local gates and review are green; the PR was opened as a draft.
      // Unless watching is off, follow its remote CI to a conclusion before
      // marking it ready — a build green on `fvm flutter` here can still fail
      // the PR's GitHub Actions (a different OS, golden tests, integration
      // suites, codegen). CI failures are fed back to a fixer up to
      // config.maxCiFixes rounds; a repo with no checks auto-skips the wait.
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

    // Red gate or rejected review: demote to draft (a prior run may have marked
    // it ready) and leave it for a human. Nothing is rolled back here.
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

  /// Watches the just-opened (draft) PR's remote CI to a conclusion, auto-fixing
  /// failures up to [Config.maxCiFixes] rounds. The local gates and the review
  /// are already green; this is the remote backstop a `fvm flutter` build cannot
  /// see (a different OS, golden tests, integration suites, codegen). Polling
  /// backs off (30s → 60s → 120s via [ciPollInterval]) with a 60s grace before
  /// trusting an empty rollup, so a PR whose checks have not registered yet is
  /// not mistaken for one with no CI. Returns:
  ///
  /// - [_CiOutcome.ready]    CI passed and the branch is not in conflict.
  /// - [_CiOutcome.noCi]     no checks after the grace — caller marks ready.
  /// - [_CiOutcome.failed]   CI stayed red past the fix budget, a fix regressed
  ///                         the local gates / produced no change / leaked a
  ///                         secret, the push failed, or the branch conflicts.
  /// - [_CiOutcome.timedOut] CI never settled within [Config.ciTimeout].
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
    // after this grace. A fix push extends it (the new commit's run must
    // register), so a freshly-pushed head is never misread as no-CI.
    var graceUntil = start.add(const Duration(seconds: 60));
    var fixes = 0;

    while (true) {
      final status = await gh.prCiStatus(url);
      switch (status.state) {
        case CiState.passing:
          // A branch that conflicts with base cannot merge regardless of CI, so
          // that is a human's call — leave it a draft rather than ready.
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
          // The fix is pushed; the new commit's CI needs to register. Reset the
          // grace so the next poll waits out the queueing run, not the stale
          // failed one.
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

  /// Pushes [branch] and opens the single whole-PRD PR — or reuses the one that
  /// already tracks [branch], so a re-run updates the existing PR in place
  /// instead of opening a duplicate. Returns the PR url, or null on push/create
  /// failure.
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

  /// Reads the PRD's analyze + test log tails and renders them via the pure
  /// [gateEvidence] for the PR description. The FS read stays here; the wording
  /// is unit-tested in `pr_comments.dart`.
  String _gateEvidence(int parent) => gateEvidence([
    for (final (label, path) in [
      ('analyze', _analyzeLogFor(parent)),
      ('test', _testLogFor(parent)),
    ])
      if (File(path).existsSync()) (label, _tail(path, 15)),
  ]);

  /// Reads the failing analyze/test log tails and renders the handoff via the
  /// pure [failComment]. The FS read stays here; the wording is unit-tested.
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
