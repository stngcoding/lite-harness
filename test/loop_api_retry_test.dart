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

/// An `error_during_execution` result with an overloaded status — the shape of
/// an exhausted internal API retry, which the loop should treat as transient.
const _transientResult = ResultEvent(
  subtype: 'error_during_execution',
  isError: true,
  costUsd: 0,
  numTurns: 1,
  durationMs: 1,
  permissionDenials: 0,
  apiErrorStatus: 529,
  resultText: 'Overloaded',
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
  Future<void> commentOnIssue(int number, String body) async {}
}

class FakeGit extends GitOps {
  FakeGit() : super(ProcessRunner());

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
  Future<bool> commitStaged(String message) async => true;
  @override
  Future<void> tagFail(int issueNumber) async {}
  @override
  Future<void> resetHard(String ref) async {}
  @override
  Future<List<String>> changedFiles(String baseline) async => const [];
}

/// Returns a transient API failure the first [transient] times `implement` is
/// called, then a clean success.
class FlakyClaude extends ClaudeRunner {
  FlakyClaude(this.transient) : super(ProcessRunner());

  int transient;
  var calls = 0;

  @override
  Future<ClaudeRun> implement({
    required String model,
    required String prompt,
    String systemAppend = '',
  }) async {
    calls++;
    if (transient > 0) {
      transient--;
      return const ClaudeRun(transcript: '', result: _transientResult);
    }
    return const ClaudeRun(transcript: '', result: _okResult);
  }

  @override
  Future<ClaudeRun> verify(String prompt) async =>
      const ClaudeRun(transcript: 'VERDICT: PASS', result: _okResult);

  @override
  Future<ClaudeRun> classify(String prompt) async =>
      const ClaudeRun(transcript: 'LANE: normal', result: _okResult);
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

Config _config() => const Config(
  repo: 'o/r',
  state: 'open',
  base: 'dev',
  model: 'sonnet',
  dryRun: false,
  issueNumber: 9,
  concurrency: 1,
  watchCi: false,
);

HarnessLoop _loop(FakeGh gh, FlakyClaude claude, FakeGit git) => HarnessLoop(
  config: _config(),
  gh: gh,
  git: git,
  claude: claude,
  proc: ProcessRunner(),
  prompts: _prompts(),
  traces: _tempTraces(),
  // Don't actually sleep between retries; keep the 3-retry cap.
  apiRetryBackoff: const [Duration.zero, Duration.zero, Duration.zero],
);

void main() {
  test('a transient API failure is retried, then the run proceeds', () async {
    final gh = FakeGh();
    final claude = FlakyClaude(1);

    final code = await _loop(gh, claude, FakeGit()).run();

    expect(code, 0);
    expect(claude.calls, 2, reason: 'one transient retry, then success');
    expect(gh.closed, [9], reason: 'gates pass on the clean run');
    expect(gh.relabeled, isEmpty);
  });

  test(
    'a transient API failure that never clears aborts after the cap',
    () async {
      final gh = FakeGh();
      final claude = FlakyClaude(99);

      final code = await _loop(gh, claude, FakeGit()).run();

      expect(code, 2, reason: 'ClaudeAbort exit code');
      expect(claude.calls, 4, reason: 'first call + 3 retries, then give up');
      expect(gh.closed, isEmpty);
    },
  );
}
