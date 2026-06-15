import 'dart:io';

import 'ansi.dart';
import 'claude.dart';
import 'config.dart';
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
    Ansi? ansi,
  }) : ansi = ansi ?? Ansi.forStdout();

  final Config config;
  final GhCli gh;
  final GitOps git;
  final ClaudeRunner claude;
  final ProcessRunner proc;
  final PromptLibrary prompts;
  final Ansi ansi;

  /// Running `claude` API spend (USD) for the PRD currently being drained,
  /// summed from each slice's `result` event. Reset when a new PRD starts.
  double _prdCostUsd = 0;

  /// Prints the active-stage marker, e.g. `▶ IMPLEMENT — #123 fix login`.
  void _phase(HarnessPhase phase, [String? detail]) =>
      print(phase.marker(ansi, detail));

  /// Aborts the whole loop when [run] hit an unrecoverable condition (rate
  /// limit, auth/billing, streaming death) — every later `claude` call would
  /// fail the same way, so there is no point grinding through the queue. A
  /// per-task failure (max-turns, bad code) is not fatal and returns normally.
  void _abortIfFatal(ClaudeRun run, String context) {
    final fatal = run.fatalError;
    if (fatal != null) throw ClaudeAbort('$context — $fatal');
  }

  Future<int> run() async {
    if (config.dryRun) return _dryRun();
    try {
      if (config.issueNumber != null) {
        return await _runSingle(config.issueNumber!);
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
      return 0;
    } on ClaudeAbort catch (e) {
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

  Future<int?> _selectActivePrd() async {
    for (final issue in await gh.readyIssues(config.state)) {
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
        print('  cannot checkout $branch; skipping PRD');
        return false;
      }
    } else if (!await git.checkoutNew(branch, 'origin/${config.base}')) {
      print('  cannot create $branch; skipping PRD');
      return false;
    }
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
        if (umbrellas.contains(issue.number)) {
          await gh.dropAgentLabel(issue.number);
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
        print('  cannot checkout $branch; skipping stranded PRD #$parent');
        continue;
      }
      _prdCostUsd = 0;
      print('');
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
    for (final branch in await git.localBranches()) {
      final match = RegExp(r'^(\d+)-').firstMatch(branch);
      if (match == null) continue;
      branchByParent.putIfAbsent(int.parse(match.group(1)!), () => branch);
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
    final comments = await gh.issueComments(issue.number);

    final issuePhase = phaseOf(issue.body);
    const rule = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━';
    print(ansi.dim(rule));
    print('  ${ansi.bold('Issue #${issue.number}')}: ${issue.title}');
    if (issuePhase != null) print('  Phase: ${ansi.dim(issuePhase)}');
    print('  ${ansi.dim(issue.url)}');
    print(ansi.dim(rule));

    final baseline = await git.head();

    _phase(HarnessPhase.implement, '#${issue.number} ${issue.title}');
    final run = await claude.implement(
      model: config.model,
      prompt: prompts.implementer(issue: issue, comments: comments),
    );
    _prdCostUsd += run.result?.costUsd ?? 0;
    _abortIfFatal(run, 'Implement #${issue.number}');
    final implementSummary = run.result == null
        ? ''
        : '\n\nImplement: ${run.result!.summary}.';
    print('');

    if (!await git.hasDrift()) {
      // No uncommitted changes — check if current state already passes gates.
      // This covers the case where a prior human commit resolved the issue and
      // the agent correctly identifies no further work is needed.
      final analyzeOk = await _gate(HarnessPhase.analyze, [
        'flutter',
        'analyze',
      ], _analyzeLog);
      final testOk = await _scopedTestGate(baseline, issue.number);
      if (analyzeOk && testOk) {
        await gh.closeIssue(
          issue.number,
          'No new changes needed — current state passes all gates '
          '(analyze + scoped tests).$implementSummary',
        );
        print('  ${ansi.green('✓')} #${issue.number} already done → closed.');
        return true;
      }
      print(
        '  ${ansi.red('No changes produced for #${issue.number} → FAIL.')}',
      );
      await gh.relabelForHuman(issue.number);
      await gh.commentOnIssue(
        issue.number,
        'AFK loop produced no changes for this issue — needs human attention.',
      );
      return false;
    }

    _phase(HarnessPhase.commit, '#${issue.number}');
    final committed = await git.commitAll(
      'feat(#${issue.number}): ${issue.title}\n\n'
      'Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>',
    );
    if (!committed) {
      print('  ${ansi.red('commit failed for #${issue.number}')}');
      return false;
    }

    final analyzeOk = await _gate(HarnessPhase.analyze, [
      'flutter',
      'analyze',
    ], _analyzeLog);
    final testOk = await _scopedTestGate(baseline, issue.number);

    if (analyzeOk && testOk) {
      await gh.closeIssue(
        issue.number,
        'Verified by AFK loop on branch `${await git.currentBranch()}`: '
        'analyze + scoped tests green.$implementSummary',
      );
      print('  ${ansi.green('✓ #${issue.number} PASS → closed.')}');
      return true;
    }

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
        '  #${issue.number} FAIL → tagged ralph-fail/${issue.number}, '
        'rolled back, relabeled ready-for-human.',
      ),
    );
    return false;
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
      print(
        '  PRD #$activeParent not PR\'d '
        '(open_subs=${openSubs.length}${refs.isEmpty ? '' : ' [$refs]'}, '
        'commits_ahead=$ahead). Branch left for human.',
      );
      return;
    }

    _phase(HarnessPhase.pr, 'PRD #$activeParent');
    final title = await gh.issueTitle(activeParent);
    final branch = await git.currentBranch();
    if (!await git.pushBranch(branch)) {
      print('  ${ansi.red('push failed for $branch; leaving for human.')}');
      return;
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
    if (prUrl == null) return;

    // PR gate: the whole suite, not the per-issue scoped subset. A red base
    // (pre-existing failures) keeps the PR a draft for a human — work is never
    // discarded here, only the auto-ready signal is withheld.
    final analyzeOk = await _gate(HarnessPhase.analyze, [
      'flutter',
      'analyze',
    ], _analyzeLog);
    final testOk = await _gate(HarnessPhase.test, [
      'flutter',
      'test',
    ], _testLog);

    _phase(HarnessPhase.review, 'PR #$activeParent');
    final review = await claude.verify(
      prompts.prVerifier(
        activeParent,
        title,
        config.base,
        repo: config.repo,
        prRef: prUrl,
      ),
    );
    _prdCostUsd += review.result?.costUsd ?? 0;
    _abortIfFatal(review, 'PR review #$activeParent');
    final verdict = review.transcript;
    final reviewSummary = review.result == null
        ? ''
        : '\n\n_Review: ${review.result!.summary}._';
    final suiteLine =
        'Full suite: analyze=${analyzeOk ? 'pass' : 'fail'} '
        'test=${testOk ? 'pass' : 'fail'}.';
    await gh.commentOnPr(
      prUrl,
      '**AFK PR review (diff-verifier)**\n\n$suiteLine\n\n$verdict$reviewSummary'
      '\n\n_Total AFK spend for PRD #$activeParent: '
      '\$${_prdCostUsd.toStringAsFixed(4)}._',
    );
    if (analyzeOk && testOk && hasPassVerdict(verdict)) {
      await gh.markPrReady(prUrl);
      print('  ${ansi.green('✓ Full suite + PR review PASS → marked ready.')}');
    } else {
      print(
        ansi.red(
          '  ✗ PR left as draft for human '
          '(analyze=${analyzeOk ? 1 : 0} test=${testOk ? 1 : 0} '
          'review=${hasPassVerdict(verdict) ? 1 : 0}).',
        ),
      );
    }
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
