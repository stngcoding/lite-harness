part of 'loop.dart';

/// One in-flight parallel slice: its worktree, the cwd-scoped `git`/`claude`
/// bound to that worktree, the per-issue log sink, and the mutable status the
/// dashboard reads. [say] routes a line to the log file (never stdout) so the
/// live dashboard is never interleaved with worker output.
class _Worker {
  _Worker({
    required this.issue,
    required this.prd,
    required this.branch,
    required this.path,
    required this.git,
    required this.claude,
    required this.sink,
  });

  final Issue issue;
  final int prd;
  final String branch;
  final String path;
  final GitOps git;
  final ClaudeRunner claude;
  final IOSink sink;

  String status = 'queued';
  double? freePct;
  bool running = true;
  bool passed = false;
  bool failed = false;

  void say(String line) => sink.writeln(line);
}

/// A slice's terminal result, recorded by the worker and consumed by the merge
/// phase. [commitSha] is null when the slice needed no changes (base already
/// passed) — there is nothing to cherry-pick, but the issue is still closed.
class _WorkerOutcome {
  _WorkerOutcome({
    required this.issue,
    required this.prd,
    required this.passed,
    required this.branch,
    this.commitSha,
    this.worktreePath,
    required this.title,
    this.closeComment,
  });

  final int issue;
  final int prd;
  final bool passed;
  final String branch;
  final String? commitSha;
  final String? worktreePath;
  final String title;
  final String? closeComment;
}

extension _WorkerPool on HarnessLoop {
  // ───────────────────────── parallel mode (concurrency > 1) ──────────────────

  /// Drains the whole ready queue with a bounded worker pool. A single driver
  /// owns scheduling — only [_nextReady] picks the next eligible slice, and it
  /// runs sequentially between `await`s, so the in-flight/handled sets never
  /// race (Dart's single isolate makes the mutations between two synchronous
  /// statements atomic). Workers signal completion through [wake]; the driver
  /// keeps the pool full until nothing is ready and nothing is in flight, then
  /// integrates each PRD ([_mergeAndPrAll]). Returns the number of slices
  /// launched.
  Future<int> _drainParallel(int alreadyProcessed) async {
    final wake = StreamController<void>();
    final inFlight = <int>{};
    final running = <Future<void>>[];
    var launched = 0;
    var done = false;

    Future<void> fill() async {
      while (!done &&
          _hardAbort == null &&
          inFlight.length < config.concurrency) {
        await _awaitRateLimitClear();
        final issue = await _nextReady(inFlight);
        if (issue == null) {
          // Nothing eligible right now. If nothing is in flight either, the
          // queue is genuinely drained; otherwise an in-flight slice may yet
          // unblock a dependent, so wait for the next completion.
          if (inFlight.isEmpty) done = true;
          return;
        }
        inFlight.add(issue.number);
        _handled.add(issue.number);
        launched++;
        events.event('WORKER_LAUNCH', issue: issue.number);
        final f = _runIssueInWorktree(issue)
            .catchError((Object e, StackTrace _) {
              if (e is ClaudeAbort) _hardAbort = e;
              events.event('WORKER_ERROR', issue: issue.number, detail: '$e');
            })
            .whenComplete(() {
              inFlight.remove(issue.number);
              if (!wake.isClosed) wake.add(null);
            });
        running.add(f);
        if (config.iterations != null &&
            alreadyProcessed + launched >= config.iterations!) {
          done = true;
          return;
        }
      }
    }

    if (ansi.enabled) {
      _dashboardTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _renderDashboard(),
      );
    }

    await fill();
    if (!done || inFlight.isNotEmpty) {
      await for (final _ in wake.stream) {
        if (_hardAbort != null) {
          if (inFlight.isEmpty) break;
          continue;
        }
        await fill();
        if (done && inFlight.isEmpty) break;
      }
    }
    await wake.close();
    await Future.wait(running, eagerError: false);

    _dashboardTimer?.cancel();
    _dashboardTimer = null;
    _renderDashboard();

    if (_hardAbort == null) await _mergeAndPrAll();
    if (_hardAbort != null) throw _hardAbort!;
    return launched;
  }

  /// The next slice eligible to start: ready, not already handled or in flight,
  /// not an umbrella, and every blocker satisfied (closed on GitHub or passed
  /// earlier this run). Umbrellas are dropped inline (label removed) so they
  /// stop surfacing. Called only by the single driver, so it is TOCTOU-safe.
  Future<Issue?> _nextReady(Set<int> inFlight) async {
    final ready = await gh.readyIssues(config.state);
    final umbrellas = umbrellaNumbers(ready);
    for (final issue in ready) {
      if (umbrellas.contains(issue.number) &&
          !_handled.contains(issue.number)) {
        await gh.dropAgentLabel(issue.number);
        _handled.add(issue.number);
        events.event('UMBRELLA_DROP', issue: issue.number);
      }
    }
    final satisfied = <int>{..._passedThisRun};
    for (final blocker in {for (final i in ready) ...blockersOf(i.body)}) {
      if (!satisfied.contains(blocker) &&
          await gh.issueState(blocker) == 'CLOSED') {
        satisfied.add(blocker);
      }
    }
    final eligible = eligibleSlices(
      ready,
      satisfied: satisfied,
      excluded: {..._handled, ...inFlight},
    );
    return eligible.isEmpty ? null : eligible.first;
  }

  /// Runs a `claude` call for a parallel worker. Unlike [_abortIfFatal], a rate
  /// limit is *recoverable*: the pool pauses and the call is retried once the
  /// window resets, so a transient cap does not waste in-flight work. Only an
  /// auth/billing failure or an exhausted transient error throws [ClaudeAbort]
  /// to stop the whole pool.
  Future<ClaudeRun> _callPausing(
    Future<ClaudeRun> Function() call,
    String context,
  ) async {
    while (true) {
      final run = await _runWithApiRetry(call, context);
      if (run.rateLimited != null) {
        _noteRateLimit(run);
        await _awaitRateLimitClear();
        continue;
      }
      final fatal = run.fatalError ?? run.transientApiError;
      if (fatal != null) throw ClaudeAbort('$context — $fatal');
      return run;
    }
  }

  void _noteRateLimit(ClaudeRun run) {
    final rl = run.rateLimited;
    if (rl == null) return;
    final until = rl.resetsAt != null
        ? DateTime.fromMillisecondsSinceEpoch(rl.resetsAt! * 1000)
        : DateTime.now().add(const Duration(seconds: 60));
    if (_rateLimitPausedUntil == null ||
        until.isAfter(_rateLimitPausedUntil!)) {
      _rateLimitPausedUntil = until;
    }
    events.event('RATE_LIMIT_PAUSE', detail: rl.summary);
  }

  Future<void> _awaitRateLimitClear() async {
    final until = _rateLimitPausedUntil;
    if (until == null) return;
    final now = DateTime.now();
    if (now.isBefore(until)) await Future<void>.delayed(until.difference(now));
    _rateLimitPausedUntil = null;
  }

  void _addCost(int prd, ClaudeRun run) {
    _prdCostAccum[prd] = (_prdCostAccum[prd] ?? 0) + (run.result?.costUsd ?? 0);
  }

  /// Sets up the per-issue worktree, runs the slice in it ([_driveWorker]), and
  /// always flushes/closes the per-issue log. The branch is `ralph-slice/<n>`
  /// (the `ralph-slice/` prefix keeps it out of the `<parent>-<slug>` PRD-branch
  /// namespace [_strandedPrds] sweeps). Cut from `origin/<base>` and then
  /// true-merged with every blocker that passed *this run* (their work is not on
  /// base yet); a merge conflict is a real integration clash → handed to a human.
  Future<void> _runIssueInWorktree(Issue issue) async {
    final prd = parentOf(issue.body, issue.number);
    final prdRef = prd == issue.number ? null : prd;
    final branch = 'ralph-slice/${issue.number}';
    events.event('ISSUE_START', prd: prdRef, issue: issue.number);

    await git.fetch(config.base);
    final path = await git.createWorktree(branch, 'origin/${config.base}');
    if (path == null) {
      events.event(
        'WORKER_ERROR',
        issue: issue.number,
        detail: 'worktree create failed',
      );
      await gh.relabelForHuman(issue.number);
      _workerOutcomes[issue.number] = _WorkerOutcome(
        issue: issue.number,
        prd: prd,
        passed: false,
        branch: branch,
        title: issue.title,
      );
      return;
    }
    final wGit = GitOps(proc, workingDirectory: path);
    final passedBlockers = blockersOf(
      issue.body,
    ).where(_passedThisRun.contains).toList()..sort();
    for (final blocker in passedBlockers) {
      if (!await wGit.merge('ralph-slice/$blocker')) {
        await wGit.mergeAbort();
        events.event(
          'MERGE_CONFLICT',
          prd: prdRef,
          issue: issue.number,
          detail: 'blocker=#$blocker',
        );
        await git.removeWorktree(path);
        await git.deleteBranch(branch);
        await gh.relabelForHuman(issue.number);
        await gh.commentOnIssue(
          issue.number,
          mergeConflictComment(issue.number, blocker),
        );
        _workerOutcomes[issue.number] = _WorkerOutcome(
          issue: issue.number,
          prd: prd,
          passed: false,
          branch: branch,
          title: issue.title,
        );
        return;
      }
    }

    final logFile = File('.dartralph/logs/issue-${issue.number}.log');
    logFile.parent.createSync(recursive: true);
    final sink = logFile.openWrite();
    final worker = _Worker(
      issue: issue,
      prd: prd,
      branch: branch,
      path: path,
      git: wGit,
      claude: ClaudeRunner(
        proc,
        ansi: ansi,
        workingDirectory: path,
        logSink: sink,
      ),
      sink: sink,
    );
    _workers[issue.number] = worker;
    try {
      await _driveWorker(worker, prdRef);
    } finally {
      worker.running = false;
      await sink.flush();
      await sink.close();
    }
  }

  /// Drives one parallel slice through the shared [_runSlice] lifecycle behind a
  /// [_WorkerSliceIo] seam: git/claude are worktree-scoped, narration goes to the
  /// worker's per-issue log, `claude` calls pause the pool on a rate limit, and a
  /// pass records a [_WorkerOutcome] for the merge phase (it is *not* closed here —
  /// the merge phase closes it once its commit lands on the PRD branch) rather than
  /// closing the issue now.
  Future<void> _driveWorker(_Worker w, int? prdRef) async {
    await _runSlice(w.issue, _WorkerSliceIo(this, w, prdRef: prdRef));
  }

  void _failOutcome(_Worker w) {
    _workerOutcomes[w.issue.number] = _WorkerOutcome(
      issue: w.issue.number,
      prd: w.prd,
      passed: false,
      branch: w.branch,
      worktreePath: w.path,
      title: w.issue.title,
    );
    w.failed = true;
  }

  /// Integrates every PRD that has at least one passed slice. For each PRD:
  /// check out its `<parent>-<slug>` branch off base, cherry-pick the passed
  /// slices in issue order, then run the unchanged PR gate ([_maybeOpenPr] —
  /// full suite + diff-verifier + auto-fix). A cherry-pick conflict is a real
  /// integration clash: abort, park the slices for a human, ship a draft
  /// `[NEEDS HUMAN]` PR. Clean slices' worktrees are removed once their commit
  /// lands on the PRD branch.
  Future<void> _mergeAndPrAll() async {
    final byPrd = <int, List<_WorkerOutcome>>{};
    for (final o in _workerOutcomes.values) {
      if (o.passed) (byPrd[o.prd] ??= []).add(o);
    }
    for (final prd in byPrd.keys.toList()..sort()) {
      final slices = byPrd[prd]!..sort((a, b) => a.issue.compareTo(b.issue));
      if (!await _checkoutPrdBranch(prd)) continue;

      int? conflictSlice;
      for (final s in slices) {
        if (s.commitSha == null) continue; // "already done" — nothing to pick
        if (!await git.cherryPick(s.commitSha!)) {
          await git.cherryPickAbort();
          conflictSlice = s.issue;
          events.event('CHERRY_CONFLICT', prd: prd, issue: s.issue);
          break;
        }
      }
      _prdCostUsd = _prdCostAccum[prd] ?? 0;
      final title = await gh.issueTitle(prd);

      if (conflictSlice != null) {
        for (final s in slices) {
          await gh.relabelForHuman(s.issue);
          await gh.commentOnIssue(
            s.issue,
            integrationConflictComment(prd, conflictSlice),
          );
        }
        final url = await _openOnePr(
          prd,
          '[NEEDS HUMAN — merge conflict] $title',
          await git.currentBranch(),
        );
        if (url != null) {
          await gh.markPrDraft(url);
          await gh.commentOnPr(
            url,
            integrationConflictComment(prd, conflictSlice),
          );
        }
        print(
          ansi.red(
            '  PRD #$prd: slice #$conflictSlice conflicts on integration → '
            'draft PR for a human; worktrees kept.',
          ),
        );
        continue;
      }

      for (final s in slices) {
        await gh.closeIssue(
          s.issue,
          s.closeComment ?? 'Verified by AFK loop (parallel).',
        );
        _handled.add(s.issue);
        events.event(
          'CLOSE',
          prd: prd == s.issue ? null : prd,
          issue: s.issue,
          detail: 'pass-parallel',
        );
        if (s.worktreePath != null) {
          await git.removeWorktree(s.worktreePath!);
          await git.deleteBranch(s.branch);
        }
      }
      await _maybeOpenPr(prd);
    }
  }

  /// Re-renders the live worker dashboard in place (cursor-up + clear-below), so
  /// the per-issue agent transcripts can stream to their log files while the
  /// console shows one compact status line per in-flight slice. No-op when
  /// stdout is not a terminal (the per-issue logs + event log are the record).
  void _renderDashboard() {
    if (!ansi.enabled) return;
    final running = _workers.values.where((w) => w.running).toList()
      ..sort((a, b) => a.issue.number.compareTo(b.issue.number));
    final passed = _workers.values.where((w) => w.passed).length;
    final failed = _workers.values.where((w) => w.failed).length;
    final lines = <String>[
      '${ansi.cyan('▶ pool')} ${ansi.dim('c=${config.concurrency}')} · '
          '${ansi.green('$passed pass')} · ${ansi.red('$failed fail')} · '
          '${running.length} running'
          '${_rateLimitPausedUntil != null ? ansi.yellow(' · paused (rate limit)') : ''}',
      for (final w in running)
        '  #${w.issue.number} ${w.status.padRight(9)}'
            '${w.freePct == null ? '' : ' ctx ${w.freePct!.round()}% free'}',
    ];
    final buf = StringBuffer();
    if (_dashboardLines > 0) buf.write('\x1B[${_dashboardLines}A');
    buf.write('\x1B[0J');
    for (final l in lines) {
      buf.writeln(l);
    }
    _dashboardLines = lines.length;
    stdout.write(buf.toString());
  }
}
