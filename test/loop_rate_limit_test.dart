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

/// Passes the classify call, then reports a usage rate limit on `implement` —
/// the shape of the limit running out mid-slice.
class RateLimitedClaude extends ClaudeRunner {
  RateLimitedClaude() : super(ProcessRunner());

  var implementCalls = 0;

  @override
  Future<ClaudeRun> classify(String prompt) async =>
      const ClaudeRun(transcript: 'LANE: normal', result: _okResult);

  @override
  Future<ClaudeRun> implement({
    required String model,
    required String prompt,
    String systemAppend = '',
  }) async {
    implementCalls++;
    return const ClaudeRun(
      transcript: '',
      rateLimited: RateLimitEvent(
        status: 'rate_limited',
        rateLimitType: 'usage',
      ),
    );
  }

  @override
  Future<ClaudeRun> verify(String prompt) async =>
      const ClaudeRun(transcript: 'VERDICT: PASS', result: _okResult);
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

HarnessLoop _loop(FakeGh gh, RateLimitedClaude claude, FakeGit git) =>
    HarnessLoop(
      config: _config(),
      gh: gh,
      git: git,
      claude: claude,
      proc: ProcessRunner(),
      prompts: _prompts(),
      traces: _tempTraces(),
      apiRetryBackoff: const [Duration.zero, Duration.zero, Duration.zero],
    );

void main() {
  test(
    'a usage limit exits resumable (75) without penalising the issue',
    () async {
      final gh = FakeGh();
      final claude = RateLimitedClaude();

      final code = await _loop(gh, claude, FakeGit()).run();

      expect(code, 75, reason: 'EX_TEMPFAIL — resumable, re-run me');
      expect(claude.implementCalls, 1, reason: 'a rate limit is not retried');
      expect(
        gh.closed,
        isEmpty,
        reason: 'the slice never finished, so it is not closed',
      );
      expect(
        gh.relabeled,
        isEmpty,
        reason:
            'a limit-out is not the issue\'s fault — it stays '
            'ready-for-agent for a re-run, never ready-for-human',
      );
    },
  );
}
