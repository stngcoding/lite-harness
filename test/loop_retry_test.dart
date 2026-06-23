import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

/// A trace store pointed at a throwaway temp file so loop tests never write
/// into the repo's `.dartralph/`.
TraceStore _tempTraces() => TraceStore(
  '${Directory.systemTemp.createTempSync('lh-trace').path}/t.jsonl',
);

const _okResult = ResultEvent(
  subtype: 'success',
  isError: false,
  costUsd: 0,
  numTurns: 1,
  durationMs: 1,
  permissionDenials: 0,
);

Issue _issue() => const Issue(
  number: 9,
  title: 'Add thing',
  body: 'no parent',
  labels: ['ready-for-agent'],
  url: 'u/9',
);

class FakeGh extends GhCli {
  FakeGh() : super(ProcessRunner(), 'o/r');

  final closed = <int>[];
  final relabeled = <int>[];
  final comments = <String>[];

  @override
  Future<List<Issue>> readyIssues(String state) async => [_issue()];
  @override
  Future<bool> allBlockersClosed(String body) async => true;
  @override
  Future<String> issueTitle(int number) async => 'Add thing';
  @override
  Future<String> issueComments(int number) async => '';
  @override
  Future<void> closeIssue(int number, String comment) async =>
      closed.add(number);
  @override
  Future<void> relabelForHuman(int number) async => relabeled.add(number);
  @override
  Future<void> commentOnIssue(int number, String body) async =>
      comments.add(body);
}

class FakeGit extends GitOps {
  FakeGit() : super(ProcessRunner());

  final tagged = <int>[];
  var resets = 0;
  var commits = 0;

  @override
  Future<String?> parkDrift() async => null;
  @override
  Future<void> fetch(String base) async {}
  @override
  Future<bool> branchExists(String branch) async => false;
  @override
  Future<bool> checkout(String branch) async => true;
  @override
  Future<bool> checkoutNew(String branch, String from) async => true;
  @override
  Future<String> head() async => 'BASE';
  @override
  Future<String> currentBranch() async => '9-add-thing';
  @override
  Future<bool> hasDrift() async => true;
  @override
  Future<void> stageAll() async {}
  @override
  Future<String> stagedDiff() async => '';
  @override
  Future<bool> commitStaged(String message) async {
    commits++;
    return true;
  }

  @override
  Future<void> tagFail(int issueNumber) async => tagged.add(issueNumber);
  @override
  Future<void> resetHard(String ref) async => resets++;
  @override
  Future<List<String>> changedFiles(String baseline) async => const [];
}

class FakeClaude extends ClaudeRunner {
  FakeClaude({this.peakContextTokens = 0}) : super(ProcessRunner());

  /// Peak context occupancy every implement run reports — 190_000 of a 200_000
  /// window is ~5% free, below the context-starved threshold.
  final int peakContextTokens;
  final prompts = <String>[];

  @override
  Future<ClaudeRun> implement({
    required String model,
    required String prompt,
    String systemAppend = '',
  }) async {
    prompts.add(prompt);
    return ClaudeRun(
      transcript: '',
      result: _okResult,
      peakContextTokens: peakContextTokens,
    );
  }

  @override
  Future<ClaudeRun> verify(String prompt) async =>
      const ClaudeRun(transcript: 'VERDICT: PASS', result: _okResult);

  @override
  Future<ClaudeRun> classify(String prompt) async =>
      const ClaudeRun(transcript: 'LANE: normal', result: _okResult);
}

/// Fails the `analyze` gate the first [failAnalyze] times it is asked, then
/// passes. Every other command passes.
class FailingProc extends ProcessRunner {
  FailingProc(this.failAnalyze);

  int failAnalyze;

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (arguments.contains('analyze') && failAnalyze > 0) {
      failAnalyze--;
      return const ProcResult(1, 'ANALYZE BOOM', '');
    }
    return const ProcResult(0, '', '');
  }
}

PromptLibrary _prompts() => PromptLibrary(
  implementer: PromptTemplate(
    'implementer',
    '#{{ISSUE_NUMBER}}{{RETRY}}',
    const {'ISSUE_NUMBER', 'RETRY'},
  ),
  verifier: PromptTemplate('verifier', 'v', const {}),
  prVerifier: PromptTemplate('pr-verifier', 'p', const {}),
  intake: PromptTemplate('intake', 'i', const {}),
  fixer: PromptTemplate('fixer', 'fix {{FINDINGS}}', const {'FINDINGS'}),
  ciFixer: PromptTemplate('ci-fixer', 'ci {{LOGS}}', const {'LOGS'}),
);

Config _config({required int maxAttempts}) => Config(
  repo: 'o/r',
  state: 'open',
  base: 'dev',
  model: 'sonnet',
  dryRun: false,
  issueNumber: 9,
  maxAttempts: maxAttempts,
  concurrency: 1,
  watchCi: false,
);

HarnessLoop _loop(
  FakeGh gh,
  FakeClaude claude,
  FakeGit git,
  FailingProc proc, {
  required int maxAttempts,
}) => HarnessLoop(
  config: _config(maxAttempts: maxAttempts),
  gh: gh,
  git: git,
  claude: claude,
  proc: proc,
  prompts: _prompts(),
  traces: _tempTraces(),
);

void main() {
  test(
    'a sub that fails once is retried with the failing log, then closes',
    () async {
      final gh = FakeGh();
      final claude = FakeClaude();
      final git = FakeGit();

      final code = await _loop(
        gh,
        claude,
        git,
        FailingProc(1),
        maxAttempts: 3,
      ).run();

      expect(code, 0);
      expect(claude.prompts.length, 2, reason: 'one retry');
      expect(gh.closed, [9]);
      expect(gh.relabeled, isEmpty);
      // The retry prompt carries the failing analyze log back to the agent.
      expect(claude.prompts[0], '#9');
      expect(claude.prompts[1], contains('Previous attempt failed'));
      expect(claude.prompts[1], contains('ANALYZE BOOM'));
    },
  );

  test(
    'a sub that never passes is relabeled for a human after maxAttempts',
    () async {
      final gh = FakeGh();
      final claude = FakeClaude();
      final git = FakeGit();

      final code = await _loop(
        gh,
        claude,
        git,
        FailingProc(99),
        maxAttempts: 2,
      ).run();

      expect(code, 1);
      expect(claude.prompts.length, 2, reason: 'capped at maxAttempts');
      expect(gh.closed, isEmpty);
      expect(gh.relabeled, [9]);
      expect(git.tagged, [9]);
      // No context-usage was reported, so the handoff must not guess the slice
      // is too large.
      expect(gh.comments.single, isNot(contains('likely too large')));
    },
  );

  test(
    'a context-starved failing slice flags itself as too large in the handoff',
    () async {
      final gh = FakeGh();
      final claude = FakeClaude(peakContextTokens: 190000); // ~5% free
      final git = FakeGit();

      final code = await _loop(
        gh,
        claude,
        git,
        FailingProc(99),
        maxAttempts: 1,
      ).run();

      expect(code, 1);
      expect(gh.relabeled, [9]);
      expect(gh.comments.single, contains('likely too large'));
      expect(gh.comments.single, contains('splitting'));
    },
  );
}
