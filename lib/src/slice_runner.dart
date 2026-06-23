part of 'loop.dart';

/// How a slice narration line is toned in sequential mode. Parallel mode logs
/// plain text to a per-issue file, so it ignores the tone. Purely presentational.
enum _Tone { info, good, bad, dim }

/// The coarse stage a slice is in, surfaced as a stdout phase marker (sequential)
/// or a dashboard status (parallel). The `analyze` stage's marker is printed by
/// [HarnessLoop._gate] itself in sequential mode, so the sequential drive treats
/// it as a no-op to avoid a double marker.
enum _SliceStage { classify, implement, commit, analyze }

/// The per-mode seam [HarnessLoop._runSlice] drives through. Everything the slice
/// lifecycle does that differs between the sequential drive ([HarnessLoop._processSub])
/// and a parallel worker ([HarnessLoop._driveWorker]) lives behind this interface:
/// which git/claude binding to use, how a `claude` call is retried and costed,
/// where narration goes, and what a terminal pass/fail means. The lifecycle logic
/// itself is shared and lives in exactly one place.
abstract class _SliceIo {
  /// The PRD parent number (equals the slice number for a PRD-of-one).
  int get prd;

  /// The PRD parent for event/trace tagging, or null when the slice is its own
  /// PRD (so events read `prd=null`).
  int? get prdRef;

  /// The git binding for this slice — the process cwd (sequential) or the
  /// slice's own worktree (parallel).
  GitOps get git;

  /// The `claude` binding for this slice (worktree-scoped in parallel mode).
  ClaudeRunner get claude;

  /// The working directory [HarnessLoop._gate]/[HarnessLoop._scopedTestGate] run
  /// in: null in sequential mode (the process cwd) or the slice's own worktree
  /// path in parallel mode.
  String? get workingDirectory;

  /// Runs a `claude` call with this mode's policy: sequential retries a transient
  /// API error then aborts on a fatal; parallel additionally pauses the pool on a
  /// rate limit. Both fold in the run's cost.
  Future<ClaudeRun> call(Future<ClaudeRun> Function() fn, String context);

  /// Marks the slice's current coarse [stage] (phase marker vs. dashboard).
  void stage(_SliceStage stage, [String? detail]);

  /// Emits one narration line. [tone] applies only in sequential mode.
  void say(String line, {_Tone tone});

  /// Outputs an already-formatted gate line verbatim — to stdout in sequential
  /// mode, to the worker's per-issue log in parallel. Unlike [say] it adds no
  /// prefix or tone, so the partial colouring the gates build survives intact.
  void emit(String line);

  /// Prints the analyze/test gate's stdout phase marker in sequential mode; a
  /// no-op in parallel, where the dashboard owns the console.
  void gatePhase(HarnessPhase phase);

  /// The issue header banner, printed once in sequential mode; a no-op in
  /// parallel mode (the dashboard owns the console).
  void banner(Issue issue);

  /// Records the last implement run's context headroom (drives the dashboard in
  /// parallel mode; ignored in sequential).
  void onFreePct(double? freePct);

  /// Terminal pass: sequential closes the issue now; parallel records an outcome
  /// (capturing its own commit sha) the merge phase integrates and closes later.
  /// Returns true.
  Future<bool> pass({
    required Issue issue,
    required bool noChanges,
    required String implementSummary,
  });

  /// Terminal fail, called after the shared tag/reset/relabel/comment rollback
  /// already ran in the lifecycle: sequential just returns false; parallel
  /// additionally records a failed outcome. Returns false.
  bool fail();
}

/// Sequential drive: git/claude are the process-cwd bindings, narration goes to
/// stdout with ansi tone, and a pass closes the issue immediately.
class _SeqSliceIo implements _SliceIo {
  _SeqSliceIo(this._loop, {required this.prd, required this.prdRef});

  final HarnessLoop _loop;
  @override
  final int prd;
  @override
  final int? prdRef;

  @override
  GitOps get git => _loop.git;
  @override
  ClaudeRunner get claude => _loop.claude;
  @override
  String? get workingDirectory => null;

  @override
  Future<ClaudeRun> call(
    Future<ClaudeRun> Function() fn,
    String context,
  ) async {
    final run = await _loop._runWithApiRetry(fn, context);
    _loop._prdCostUsd += run.result?.costUsd ?? 0;
    _loop._abortIfFatal(run, context);
    return run;
  }

  @override
  void stage(_SliceStage stage, [String? detail]) {
    switch (stage) {
      case _SliceStage.classify:
        _loop._phase(HarnessPhase.classify, detail);
      case _SliceStage.implement:
        _loop._phase(HarnessPhase.implement, detail);
      case _SliceStage.commit:
        _loop._phase(HarnessPhase.commit, detail);
      case _SliceStage.analyze:
        break; // _gate prints the analyze/test phase marker itself.
    }
  }

  @override
  void say(String line, {_Tone tone = _Tone.info}) {
    final painted = switch (tone) {
      _Tone.info => line,
      _Tone.good => _loop.ansi.green(line),
      _Tone.bad => _loop.ansi.red(line),
      _Tone.dim => _loop.ansi.dim(line),
    };
    print('  $painted');
  }

  @override
  void emit(String line) => print(line);

  @override
  void gatePhase(HarnessPhase phase) => _loop._phase(phase);

  @override
  void banner(Issue issue) {
    final issuePhase = phaseOf(issue.body);
    const rule = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━';
    print(_loop.ansi.dim(rule));
    print('  ${_loop.ansi.bold('Issue #${issue.number}')}: ${issue.title}');
    if (issuePhase != null) print('  Phase: ${_loop.ansi.dim(issuePhase)}');
    print('  ${_loop.ansi.dim(issue.url)}');
    print(_loop.ansi.dim(rule));
  }

  @override
  void onFreePct(double? freePct) {}

  @override
  Future<bool> pass({
    required Issue issue,
    required bool noChanges,
    required String implementSummary,
  }) async {
    if (noChanges) {
      await _loop.gh.closeIssue(
        issue.number,
        'No new changes needed — current state passes all gates '
        '(analyze + scoped tests).$implementSummary',
      );
      _loop.events.event(
        'CLOSE',
        prd: prdRef,
        issue: issue.number,
        detail: 'no-changes-pass',
      );
      say('✓ #${issue.number} already done → closed.', tone: _Tone.good);
    } else {
      await _loop.gh.closeIssue(
        issue.number,
        'Verified by AFK loop on branch `${await _loop.git.currentBranch()}`: '
        'analyze + scoped tests green.$implementSummary',
      );
      _loop.events.event(
        'CLOSE',
        prd: prdRef,
        issue: issue.number,
        detail: 'pass',
      );
      say('✓ #${issue.number} PASS → closed.', tone: _Tone.good);
    }
    return true;
  }

  @override
  bool fail() => false;
}

/// Parallel drive: git/claude are worktree-scoped, narration goes to the worker's
/// per-issue log, and a pass is recorded for the merge phase rather than closing
/// the issue now (its commit must first land on the PRD branch).
class _WorkerSliceIo implements _SliceIo {
  _WorkerSliceIo(this._loop, this._w, {required this.prdRef});

  final HarnessLoop _loop;
  final _Worker _w;
  @override
  final int? prdRef;

  @override
  int get prd => _w.prd;
  @override
  GitOps get git => _w.git;
  @override
  ClaudeRunner get claude => _w.claude;
  @override
  String? get workingDirectory => _w.path;

  @override
  Future<ClaudeRun> call(
    Future<ClaudeRun> Function() fn,
    String context,
  ) async {
    final run = await _loop._callPausing(fn, context);
    _loop._addCost(_w.prd, run);
    return run;
  }

  @override
  void stage(_SliceStage stage, [String? detail]) => _w.status = stage.name;

  @override
  void say(String line, {_Tone tone = _Tone.info}) => _w.say(line);

  @override
  void emit(String line) => _w.say(line);

  @override
  void gatePhase(HarnessPhase phase) {}

  @override
  void banner(Issue issue) {}

  @override
  void onFreePct(double? freePct) => _w.freePct = freePct;

  @override
  Future<bool> pass({
    required Issue issue,
    required bool noChanges,
    required String implementSummary,
  }) async {
    _loop._passedThisRun.add(issue.number);
    _loop._workerOutcomes[issue.number] = _WorkerOutcome(
      issue: issue.number,
      prd: _w.prd,
      passed: true,
      branch: _w.branch,
      commitSha: noChanges ? null : await git.head(),
      worktreePath: _w.path,
      title: issue.title,
      closeComment: noChanges
          ? 'No new changes needed — base already passes all gates '
                '(analyze + scoped tests).$implementSummary'
          : 'Verified by AFK loop (parallel) on `${_w.branch}`: '
                'analyze + scoped tests green.$implementSummary',
    );
    _w.passed = true;
    say(
      noChanges
          ? '✓ already done (no changes) → will close at integration.'
          : '✓ PASS → will integrate at merge.',
    );
    return true;
  }

  @override
  bool fail() {
    _loop._failOutcome(_w);
    return false;
  }
}

extension _SliceLifecycle on HarnessLoop {
  Future<bool> _processSub(Issue issue) async {
    _handled.add(issue.number);
    final parent = parentOf(issue.body, issue.number);
    final prdRef = parent == issue.number ? null : parent;
    events.event('ISSUE_START', prd: prdRef, issue: issue.number);
    return _runSlice(issue, _SeqSliceIo(this, prd: parent, prdRef: prdRef));
  }

  /// The slice lifecycle shared by both drives: classify the risk lane, then up
  /// to [Config.maxAttempts] rounds of implement → commit (secret-scanned) →
  /// analyze + scoped test, rolling back and feeding the failing logs forward on
  /// each miss; a terminal pass closes/integrates the issue, a terminal fail tags
  /// and hands it to a human. Every difference between the sequential drive and a
  /// parallel worker — the git/claude binding, the API-call policy, where
  /// narration goes, and what a pass/fail does — is behind [io] ([_SeqSliceIo] /
  /// [_WorkerSliceIo]), so this method is the single source of truth. Returns
  /// whether the slice passed.
  Future<bool> _runSlice(Issue issue, _SliceIo io) async {
    final analyzeLog = _analyzeLogFor(issue.number);
    final testLog = _testLogFor(issue.number);
    final prdRef = io.prdRef;
    final comments = await gh.issueComments(issue.number);
    final coherence = await _coherenceContext(prdRef, issue.number);
    io.banner(issue);

    // Friction this slice hits, deduped (a Set): one TraceRecord is appended
    // per terminal outcome, so a gate that fails on every attempt counts once.
    final frictions = <FrictionKind>{};

    // Classify the slice's risk lane before implementing. An isolated intake
    // agent (its own system prompt) reads the issue + PRD context and emits a
    // bare `LANE:` line. The lane only tunes the implementer guidance and the
    // PR reviewer's bar — it never blocks the loop, so an unparseable verdict
    // safely defaults to `normal`.
    io.stage(_SliceStage.classify, '#${issue.number}');
    Future<ClaudeRun> classify() async {
      final run = await io.call(
        () => io.claude.classify(
          prompts.intake(issue: issue, prdContext: coherence.prdContext),
        ),
        'Classify #${issue.number}',
      );
      _recordCall(CallPhase.classify, run, issue: issue.number, prd: prdRef);
      return run;
    }

    var classifyRun = await classify();
    var parsedLane = parseLane(classifyRun.transcript);
    if (parsedLane == null) {
      // Intake emitted no bare LANE: line — retry once before defaulting, since
      // a single dropped line is usually transient, not a real classification.
      io.say(
        'Intake emitted no lane — retrying classification once.',
        tone: _Tone.dim,
      );
      classifyRun = await classify();
      parsedLane = parseLane(classifyRun.transcript);
    }
    // A missing lane is only friction worth reporting when the slice does not
    // pass anyway — defaulting to `normal` on a slice that then sails through
    // gates is harmless noise. recordTrace adds classifyFail per outcome.
    final laneMissing = parsedLane == null;
    final lane = parsedLane ?? RiskLane.normal;
    final prevLane = _prdLane[io.prd];
    if (prevLane == null || lane.index > prevLane.index) {
      _prdLane[io.prd] = lane;
    }
    events.event('LANE', prd: prdRef, issue: issue.number, detail: lane.label);
    io.say(
      'Risk lane: ${lane.label}'
      '${laneMissing ? ' (defaulted; intake emitted none)' : ''}',
    );

    final baseline = await io.git.head();

    // One sub-issue gets up to `config.maxAttempts` shots: implement → commit
    // → gate. A failing attempt is rolled back to [baseline] and the agent is
    // re-run with the failing analyze/test logs fed back via `{{RETRY}}`, so it
    // fixes forward instead of repeating the same mistake. Only after every
    // attempt fails does the issue get tagged and handed to a human.
    var analyzeOk = false;
    var testOk = false;
    var implementSummary = '';
    var ctxDetail = '';
    var retry = '';

    // The model the last implement attempt ran on — recorded in the trace so the
    // lane→model tiering (and any retry escalation) is visible in the log.
    var lastModel = '';

    // Whether the last implement run finished low on context headroom (<15%
    // free), so a slice that then failed can be flagged as likely too big.
    var contextStarved = false;

    // The repo's recurring error signatures, fed to the implementer on its first
    // attempt only (a retry already carries the specific failing logs). Advisory.
    final pitfalls = recurringSignatures(traces.readAll());

    // Appends this slice's single trace at a terminal outcome. Captures
    // [analyzeOk]/[testOk]/[ctxDetail] by reference so the detail reflects the
    // last gate and the last implement run's context headroom. A missing lane
    // only counts as friction on a non-pass outcome (denoise — see above).
    // [signature] is the one-line gate error this outcome left behind (null on a
    // pass) — what [recurringSignatures] later aggregates into the digest above.
    void recordTrace(String outcome, int attempts, {String? signature}) {
      final hit = {...frictions};
      if (laneMissing && outcome != 'pass') hit.add(FrictionKind.classifyFail);
      traces.append(
        TraceRecord(
          ts: DateTime.now().toIso8601String(),
          issue: issue.number,
          prd: prdRef,
          lane: lane,
          outcome: outcome,
          attempts: attempts,
          frictions: hit.toList(),
          detail:
              'analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}$ctxDetail',
          signature: signature,
          model: lastModel.isEmpty ? null : lastModel,
        ),
      );
    }

    for (var attempt = 1; attempt <= config.maxAttempts; attempt++) {
      if (attempt > 1) {
        io.say(
          '↻ retry $attempt/${config.maxAttempts} for #${issue.number} '
          '— feeding the failing logs back to the agent.',
          tone: _Tone.dim,
        );
        await io.git.resetHard(baseline);
      }

      // Start the slice on its risk lane's floor model and climb one rung toward
      // the run's ceiling (`config.model`) on each retry, so a cheap model takes
      // the first shot and a smarter one is only paid for when a gate fails.
      final model = modelForAttempt(lane, attempt, ceiling: config.model);
      lastModel = model;
      io.stage(
        _SliceStage.implement,
        '#${issue.number} ${issue.title} [$model]'
        '${attempt > 1 ? ' (attempt $attempt/${config.maxAttempts})' : ''}',
      );
      events.event(
        'IMPLEMENT',
        prd: prdRef,
        issue: issue.number,
        detail: 'attempt=$attempt/${config.maxAttempts} model=$model',
      );
      final run = await io.call(
        () => io.claude.implement(
          model: model,
          prompt: prompts.implementer(
            issue: issue,
            comments: comments,
            prdContext: coherence.prdContext,
            sliceMap: coherence.sliceMap,
            base: config.base,
            retry: retry,
            lane: lane,
            pitfalls: attempt == 1 ? pitfalls : const [],
          ),
          systemAppend: rulesSystemPrompt,
        ),
        'Implement #${issue.number}',
      );
      _recordCall(
        CallPhase.implement,
        run,
        issue: issue.number,
        prd: prdRef,
        model: model,
        attempt: attempt,
      );
      implementSummary = run.result == null
          ? ''
          : '\n\nImplement: ${run.result!.summary}.';
      final freePct = run.contextFreePct;
      contextStarved = freePct != null && freePct < 15;
      io.onFreePct(freePct);
      ctxDetail = freePct == null ? '' : ' ctx=${freePct.round()}%free';

      if (!await io.git.hasDrift()) {
        // No uncommitted changes — current state may already satisfy the issue
        // (e.g. a prior human commit resolved it), or the agent simply produced
        // nothing this attempt. Gate it: green means done; otherwise retry.
        io.stage(_SliceStage.analyze);
        analyzeOk = await _gate(
          HarnessPhase.analyze,
          ['flutter', 'analyze'],
          analyzeLog,
          io: io,
        );
        testOk = await _scopedTestGate(baseline, issue.number, testLog, io);
        _logGates(prdRef, issue.number, analyzeOk: analyzeOk, testOk: testOk);
        if (analyzeOk && testOk) {
          recordTrace('pass', attempt);
          return io.pass(
            issue: issue,
            noChanges: true,
            implementSummary: implementSummary,
          );
        }
        frictions.add(FrictionKind.noChanges);
        if (!analyzeOk) frictions.add(FrictionKind.gateAnalyzeFail);
        if (!testOk) frictions.add(FrictionKind.gateTestFail);
        events.event(
          'RETRY',
          prd: prdRef,
          issue: issue.number,
          detail: 'no-changes attempt=$attempt/${config.maxAttempts}',
        );
        retry = _retryFeedback(
          analyzeOk: analyzeOk,
          testOk: testOk,
          analyzeLog: analyzeLog,
          testLog: testLog,
          noChanges: true,
        );
        io.say(
          'No changes produced for #${issue.number} '
          '(attempt $attempt/${config.maxAttempts}).',
          tone: _Tone.bad,
        );
        continue;
      }

      io.stage(_SliceStage.commit, '#${issue.number}');
      await io.git.stageAll();
      final leaks = scanSecrets(await io.git.stagedDiff());
      if (leaks.isNotEmpty) {
        frictions.add(FrictionKind.secretLeak);
        recordTrace('fail', attempt);
        events.event(
          'SECRET_BLOCK',
          prd: prdRef,
          issue: issue.number,
          detail: leaks.join('; '),
        );
        await io.git.tagFail(issue.number);
        await io.git.resetHard(baseline);
        await gh.relabelForHuman(issue.number);
        await gh.commentOnIssue(issue.number, secretBlockComment(leaks));
        io.say(
          '#${issue.number} BLOCKED — apparent secret in the diff; '
          'rolled back, relabeled ready-for-human.',
          tone: _Tone.bad,
        );
        return io.fail();
      }
      final committed = await io.git.commitStaged(
        'feat(#${issue.number}): ${issue.title}\n\n'
        'Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>',
      );
      if (!committed) {
        events.event('COMMIT_FAIL', prd: prdRef, issue: issue.number);
        frictions.add(FrictionKind.commitFail);
        recordTrace('fail', attempt);
        io.say('commit failed for #${issue.number}.', tone: _Tone.bad);
        return io.fail();
      }
      events.event('COMMIT', prd: prdRef, issue: issue.number);

      io.stage(_SliceStage.analyze);
      analyzeOk = await _gate(
        HarnessPhase.analyze,
        ['flutter', 'analyze'],
        analyzeLog,
        io: io,
      );
      testOk = await _scopedTestGate(baseline, issue.number, testLog, io);
      _logGates(prdRef, issue.number, analyzeOk: analyzeOk, testOk: testOk);

      if (analyzeOk && testOk) {
        recordTrace('pass', attempt);
        return io.pass(
          issue: issue,
          noChanges: false,
          implementSummary: implementSummary,
        );
      }

      if (!analyzeOk) frictions.add(FrictionKind.gateAnalyzeFail);
      if (!testOk) frictions.add(FrictionKind.gateTestFail);
      events.event(
        'RETRY',
        prd: prdRef,
        issue: issue.number,
        detail:
            'attempt=$attempt/${config.maxAttempts} '
            'analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}',
      );
      retry = _retryFeedback(
        analyzeOk: analyzeOk,
        testOk: testOk,
        analyzeLog: analyzeLog,
        testLog: testLog,
        previousAttempt: previousAttemptBlock(
          await io.git.diff(baseline),
          await io.git.diffStat(baseline),
        ),
      );
      io.say(
        '#${issue.number} attempt $attempt/${config.maxAttempts} FAILED '
        '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}).',
        tone: _Tone.bad,
      );
    }

    // Every attempt failed — preserve the last try and hand off to a human.
    frictions.add(FrictionKind.retryExhausted);
    // A slice that failed while nearly out of context is likely too big to land
    // in one pass — flag it so the human (and the friction report) can see it.
    if (contextStarved) frictions.add(FrictionKind.contextStarved);
    final signature = !analyzeOk && File(analyzeLog).existsSync()
        ? errorSignature(File(analyzeLog).readAsStringSync())
        : !testOk && File(testLog).existsSync()
        ? errorSignature(File(testLog).readAsStringSync())
        : null;
    recordTrace('fail', config.maxAttempts, signature: signature);
    events.event(
      'FAIL',
      prd: prdRef,
      issue: issue.number,
      detail:
          'attempts=${config.maxAttempts} '
          'analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0}',
    );
    await io.git.tagFail(issue.number);
    await io.git.resetHard(baseline);
    await gh.relabelForHuman(issue.number);
    await gh.commentOnIssue(
      issue.number,
      _failComment(
        issue.number,
        analyzeOk: analyzeOk,
        testOk: testOk,
        analyzeLog: analyzeLog,
        testLog: testLog,
        implementSummary: implementSummary,
        contextStarved: contextStarved,
      ),
    );
    io.say(
      '#${issue.number} FAIL after ${config.maxAttempts} attempt(s) → '
      'tagged ralph-fail/${issue.number}, rolled back, '
      'relabeled ready-for-human.',
      tone: _Tone.bad,
    );
    return io.fail();
  }

  /// The `{{RETRY}}` block fed to the implementer on a re-attempt: which gate
  /// failed plus the tail of its log, so the agent fixes the real error instead
  /// of repeating the same attempt blind.
  String _retryFeedback({
    required bool analyzeOk,
    required bool testOk,
    required String analyzeLog,
    required String testLog,
    bool noChanges = false,
    String previousAttempt = '',
  }) {
    final sections = <String>[];
    if (noChanges) {
      sections.add(
        'Your previous attempt produced NO file changes, yet the issue is not '
        'satisfied. You must actually edit the code this time.',
      );
    }
    if (!analyzeOk && File(analyzeLog).existsSync()) {
      sections.add(
        '`fvm flutter analyze` FAILED:\n```\n${_tail(analyzeLog, 40)}\n```',
      );
    }
    if (!testOk && File(testLog).existsSync()) {
      sections.add(
        '`fvm flutter test` FAILED:\n```\n${_tail(testLog, 40)}\n```',
      );
    }
    return '\n---\n## Previous attempt failed — fix these before finishing\n'
        'A prior automated attempt at this exact issue did not pass the gates. '
        'Treat the errors below as the source of truth and resolve every one '
        'of them.\n\n${sections.join('\n\n')}\n$previousAttempt';
  }

  /// The per-issue test gate: runs only the tests the slice's diff scopes to
  /// (changed `*_test.dart` plus the mirror test of each changed `lib/` file),
  /// so a slice is never failed for a pre-existing red test it did not touch.
  /// The whole suite runs once at the PR gate. An empty scope passes — there is
  /// nothing the slice changed to test here; the PR gate is the backstop.
  Future<bool> _scopedTestGate(
    String baseline,
    int number,
    String testLog,
    _SliceIo io,
  ) async {
    final root = io.workingDirectory;
    final scoped =
        scopedTestFiles(await io.git.changedFiles(baseline))
            .where(
              (path) => File(root == null ? path : '$root/$path').existsSync(),
            )
            .toList()
          ..sort();
    if (scoped.isEmpty) {
      io.emit(
        '  ${ansi.dim('No scoped tests for #$number '
        '→ test gate skipped (full suite runs at PR).')}',
      );
      return true;
    }
    io.emit(
      '  ${ansi.dim('Scoped tests (${scoped.length}): ${scoped.join(', ')}')}',
    );
    return _gate(
      HarnessPhase.test,
      ['flutter', 'test', ...scoped],
      testLog,
      io: io,
    );
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

  /// Runs a `fvm` gate, writing its combined output to [logPath]. Within a slice
  /// the [io] seam decides where it runs and narrates (parallel scopes it to the
  /// worker's worktree and logs to its per-issue file so the console stays free
  /// for the dashboard; sequential runs in the process cwd and prints the stage
  /// marker + result line to stdout). The PR gate passes no [io] — it always runs
  /// in the process cwd and prints to stdout.
  Future<bool> _gate(
    HarnessPhase phase,
    List<String> arguments,
    String logPath, {
    _SliceIo? io,
  }) async {
    if (io == null) {
      _phase(phase);
    } else {
      io.gatePhase(phase);
    }
    final result = await proc.run(
      'fvm',
      arguments,
      workingDirectory: io?.workingDirectory,
    );
    File(logPath).writeAsStringSync('${result.stdout}${result.stderr}');
    final mark = result.ok ? ansi.green('✓ pass') : ansi.red('✗ fail');
    final line = '  $mark  fvm ${arguments.join(' ')}';
    if (io == null) {
      print(line);
    } else {
      io.emit(line);
    }
    return result.ok;
  }
}
