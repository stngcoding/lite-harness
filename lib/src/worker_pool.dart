part of 'loop.dart';

/// One in-flight parallel slice: its worktree, the worktree-scoped `git`/`claude`,
/// the per-issue log sink, and the status the dashboard reads. [say] writes to
/// the log file (never stdout) so the dashboard never tears.
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

  void say(String line) => sink.writeln(line);
}

/// A slice's terminal result, recorded by the worker for the merge phase.
/// [commitSha] is null when the slice needed no changes — nothing to
/// cherry-pick, but the issue still closes.
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

  /// Drains the ready queue with a bounded worker pool. A single driver
  /// schedules — only [_nextReady] hands out work, serially between `await`s, so
  /// the in-flight set never races (single isolate, no mutex needed). Keeps the
  /// pool full until nothing is ready or in flight, then integrates each PRD
  /// ([_mergeAndPrAll]). Returns the slice count launched.
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
        final issue = await _nextReady(inFlight);
        if (issue == null) {
          // Nothing ready. Drained only if nothing is in flight either; else an
          // in-flight slice may yet unblock a dependent.
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

    if (_hardAbort == null) {
      await _mergeAndPrAll();
      return launched;
    }
    // A limit or hard failure stopped the pool: checkpoint passed slices onto
    // their PRD branches and clean up before unwinding, so a re-run resumes.
    await _checkpointAndCleanup();
    throw _hardAbort!;
  }

  /// The next eligible slice: ready, not handled or in flight, not an umbrella,
  /// every blocker satisfied (closed on GitHub or passed this run). Umbrellas are
  /// label-dropped inline so they stop surfacing. Single-driver only, so
  /// TOCTOU-safe.
  Future<Issue?> _nextReady(Set<int> inFlight) async {
    final ready = await gh.readyIssues(config.state);
    final byNum = {for (final i in ready) i.number: i};
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
    // Implicit file-overlap edges serialise same-PRD co-editors no `## Blocked
    // by` declared. Non-umbrella ready only: an umbrella never passes, so an edge
    // to one would deadlock its dependents. Scope is the exact diff once passed,
    // else the body-parsed prediction.
    Set<String> scopeOf(int n) =>
        _sliceScope[n] ??
        (byNum[n] == null ? const {} : predictScope(byNum[n]!));
    final implicit = implicitBlockers(
      [
        for (final i in ready)
          if (!umbrellas.contains(i.number)) i,
      ],
      scopeOf,
      (i) => parentOf(i.body, i.number),
    );
    // Drop edges to a sibling that won't pass this run (handled, not passed, not
    // in flight): its work rolled back, so there is nothing to stack on and no
    // reason to starve its dependents — matching the sequential drive.
    final wontPass = _handled.difference(_passedThisRun).difference(inFlight);
    for (final edges in implicit.values) {
      edges.removeWhere(wontPass.contains);
    }
    final eligible = eligibleSlices(
      ready,
      satisfied: satisfied,
      excluded: {..._handled, ...inFlight},
      implicit: implicit,
    );
    if (eligible.isEmpty) return null;
    // Record the chosen slice's edges now (per issue, never overwritten) so a
    // later [_nextReady] can't clobber the merge base [_runIssueInWorktree] reads
    // while this worktree is still being created.
    final chosen = eligible.first;
    _implicitBlockers[chosen.number] = implicit[chosen.number] ?? const {};
    return chosen;
  }

  /// Runs a `claude` call for a parallel worker. A rate limit throws a
  /// *resumable* [ClaudeAbort] so the pool checkpoints and the process exits for
  /// a wrapper to re-run — pausing a live pool for a cap hours out orphans
  /// worktrees if killed. Transient overload is retried in-process; an exhausted
  /// transient or auth/billing failure throws a *hard* abort.
  Future<ClaudeRun> _callPausing(
    Future<ClaudeRun> Function() call,
    String context,
  ) async {
    final run = await _runWithApiRetry(call, context);
    if (run.rateLimited != null) {
      throw ClaudeAbort(
        '$context — ${run.rateLimited!.summary}',
        resumable: true,
      );
    }
    final fatal = run.fatalError ?? run.transientApiError;
    if (fatal != null) throw ClaudeAbort('$context — $fatal');
    return run;
  }

  void _addCost(int prd, ClaudeRun run) {
    _prdCostAccum[prd] = (_prdCostAccum[prd] ?? 0) + (run.result?.costUsd ?? 0);
  }

  /// Sets up the per-issue worktree, runs the slice ([_driveWorker]), and always
  /// flushes/closes its log. Branch `ralph-slice/<n>` (the prefix keeps it out of
  /// the `<parent>-<slug>` namespace [_strandedPrds] sweeps), cut from
  /// `origin/<base>` then merged with every blocker that passed this run; a merge
  /// conflict is a real integration clash → handed to a human.
  Future<void> _runIssueInWorktree(Issue issue) async {
    final prd = parentOf(issue.body, issue.number);
    final prdRef = prd == issue.number ? null : prd;
    final branch = 'ralph-slice/${issue.number}';
    events.event('ISSUE_START', prd: prdRef, issue: issue.number);

    await git.fetch(config.base);
    final path = await git.createWorktree(branch, 'origin/${config.base}');
    if (path == null) {
      // Worktree setup is infra, not the slice's content: a failure here (disk,
      // permissions, git state) isn't its fault, so leave it `ready-for-agent` to
      // retry next run. Already in `_handled`, so not re-picked this run.
      events.event(
        'WORKER_ERROR',
        issue: issue.number,
        detail: 'worktree create failed',
      );
      return;
    }
    final wGit = GitOps(proc, workingDirectory: path);
    // Merge the declared and implicit (file-overlap) blockers that passed this
    // run — their work is on a `ralph-slice/<n>` branch, not yet on base — so an
    // overlapping slice builds on its sibling instead of a stale base.
    final passedBlockers = {
      ...blockersOf(issue.body),
      ...?_implicitBlockers[issue.number],
    }.where(_passedThisRun.contains).toList()..sort();
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

  /// Drives one parallel slice through the shared [_runSlice] behind a
  /// [_WorkerSliceIo]: worktree-scoped git/claude, narration to the per-issue
  /// log, and a pass records a [_WorkerOutcome] for the merge phase instead of
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
  }

  /// Integrates every PRD with a passed slice: check out its `<parent>-<slug>`
  /// branch off base, cherry-pick the passed slices in issue order, then run the
  /// PR gate ([_maybeOpenPr]). A cherry-pick conflict first gets the
  /// [_restackSlice] backstop; only a failed re-stack is a real integration clash
  /// → park the slices and ship a draft `[NEEDS HUMAN]` PR. Worktrees are removed
  /// once their commit lands.
  /// Passed slices grouped by PRD — the unit of integration both the clean drain
  /// ([_mergeAndPrAll]) and the abort checkpoint ([_checkpointAndCleanup])
  /// assemble onto each `<parent>-<slug>` branch.
  Map<int, List<_WorkerOutcome>> _passedSlicesByPrd() {
    final byPrd = <int, List<_WorkerOutcome>>{};
    for (final o in _workerOutcomes.values) {
      if (o.passed) (byPrd[o.prd] ??= []).add(o);
    }
    return byPrd;
  }

  Future<void> _mergeAndPrAll() async {
    final byPrd = _passedSlicesByPrd();
    for (final prd in byPrd.keys.toList()..sort()) {
      final slices = byPrd[prd]!..sort((a, b) => a.issue.compareTo(b.issue));
      if (!await _checkoutPrdBranch(prd)) continue;

      int? conflictSlice;
      final restacked = <int>{};
      for (final s in slices) {
        if (s.commitSha == null) continue; // "already done" — nothing to pick
        if (await git.cherryPick(s.commitSha!)) continue;
        await git.cherryPickAbort();
        events.event('CHERRY_CONFLICT', prd: prd, issue: s.issue);
        // Backstop: the commit won't replay (it forked off a base missing a
        // sibling's edit). Re-implement on the assembled branch and re-gate;
        // only a failed re-stack hands off.
        if (await _restackSlice(prd, s)) {
          restacked.add(s.issue);
          continue;
        }
        conflictSlice = s.issue;
        break;
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
          restacked.contains(s.issue)
              ? restackCloseComment(prd, s.issue)
              : s.closeComment ?? 'Verified by AFK loop (parallel).',
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

  /// The backstop for a cherry-pick conflict: re-implement the slice on the
  /// assembled branch (via the shared [_runSlice] behind a [_RestackSliceIo], in
  /// the cwd [_mergeAndPrAll] has the PRD branch checked out) and re-gate it. A
  /// green re-run leaves the correctly-based commit on the branch; a failed one
  /// rolls back to the pre-attempt tip and hands off. The [Issue] is recovered
  /// from the retained worker. Returns whether it passed.
  Future<bool> _restackSlice(int prd, _WorkerOutcome s) async {
    final issue = _workers[s.issue]?.issue;
    if (issue == null) return false;
    final prdRef = prd == s.issue ? null : prd;
    events.event('RESTACK', prd: prdRef, issue: s.issue);
    print(
      ansi.yellow(
        '  PRD #$prd: slice #${s.issue} conflicts on cherry-pick → '
        're-stacking it on the assembled branch.',
      ),
    );
    final ok = await _runSlice(
      issue,
      _RestackSliceIo(this, prd: prd, prdRef: prdRef),
    );
    events.event(
      ok ? 'RESTACK_OK' : 'RESTACK_FAIL',
      prd: prdRef,
      issue: s.issue,
    );
    return ok;
  }

  /// Preserves completed work when a hard abort (usage limit or auth/billing
  /// failure) stops the pool before a clean drain. Unlike [_mergeAndPrAll] it
  /// never runs the PR gate (its `claude`/build calls would re-hit the same
  /// limit) — for each PRD with passed slices it cherry-picks them onto the
  /// `<parent>-<slug>` branch, pushes, and closes those issues; the PR opens on
  /// the next run. A cherry-pick conflict or failed push leaves that PRD
  /// untouched (its slices keep their worktrees and label). Every other worktree
  /// — a failed or interrupted slice — is dropped, its issue left to retry.
  Future<void> _checkpointAndCleanup() async {
    final byPrd = _passedSlicesByPrd();
    final checkpointed = <int>{};
    for (final prd in byPrd.keys.toList()..sort()) {
      final slices = byPrd[prd]!..sort((a, b) => a.issue.compareTo(b.issue));
      if (!await _checkoutPrdBranch(prd)) continue;

      var conflict = false;
      for (final s in slices) {
        if (s.commitSha == null) continue;
        if (!await git.cherryPick(s.commitSha!)) {
          await git.cherryPickAbort();
          conflict = true;
          events.event('CHECKPOINT_CONFLICT', prd: prd, issue: s.issue);
          break;
        }
      }
      if (conflict) continue;

      final branch = await git.currentBranch();
      if (!await git.pushBranch(branch)) {
        events.event(
          'CHECKPOINT_PUSH_FAIL',
          prd: prd,
          detail: 'branch=$branch',
        );
        continue;
      }
      for (final s in slices) {
        await gh.closeIssue(s.issue, checkpointCloseComment(prd));
        _handled.add(s.issue);
        checkpointed.add(s.issue);
        events.event(
          'CHECKPOINT_CLOSE',
          prd: prd == s.issue ? null : prd,
          issue: s.issue,
        );
      }
      print(
        ansi.yellow(
          '  PRD #$prd: checkpointed ${slices.length} passed slice(s) onto '
          '$branch (pushed); its PR opens on the next run.',
        ),
      );
    }

    for (final w in _workers.values) {
      final passed = _workerOutcomes[w.issue.number]?.passed ?? false;
      if (passed && !checkpointed.contains(w.issue.number)) continue;
      await git.removeWorktree(w.path);
      await git.deleteBranch(w.branch);
    }
    events.event('CHECKPOINT_DONE', detail: 'closed=${checkpointed.length}');
  }

  /// Re-renders the live dashboard in place (cursor-up + clear-below): one status
  /// line per in-flight slice while transcripts stream to their log files. No-op
  /// when stdout is not a terminal.
  void _renderDashboard() {
    if (!ansi.enabled) return;
    final running = _workers.values.where((w) => w.running).toList()
      ..sort((a, b) => a.issue.number.compareTo(b.issue.number));
    final passed = _workers.values
        .where((w) => _workerOutcomes[w.issue.number]?.passed == true)
        .length;
    final failed = _workers.values
        .where((w) => _workerOutcomes[w.issue.number]?.passed == false)
        .length;
    final lines = <String>[
      '${ansi.cyan('▶ pool')} ${ansi.dim('c=${config.concurrency}')} · '
          '${ansi.green('$passed pass')} · ${ansi.red('$failed fail')} · '
          '${running.length} running'
          '${_hardAbort != null ? ansi.yellow(' · draining (limit)') : ''}',
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
