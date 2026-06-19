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

class Box {
  Box(this.number, this.title, this.body, Set<String> labels, this.open)
    : labels = {...labels};

  final int number;
  final String title;
  final String body;
  final Set<String> labels;
  bool open;
}

Issue _toIssue(Box b) => Issue(
  number: b.number,
  title: b.title,
  body: b.body,
  labels: b.labels.toList(),
  url: 'u/${b.number}',
);

/// Models GitHub's eventually-consistent issue list: a closed issue keeps
/// showing up in the *next* `ready-for-agent` read after it was closed, before
/// the index catches up. Without an in-run guard the loop would re-implement it.
class StaleGh extends GhCli {
  StaleGh(this.boxes) : super(ProcessRunner(), 'o/r');

  final Map<int, Box> boxes;
  final closed = <int>[];
  final _staleOnce = <int>{};

  @override
  Future<List<Issue>> issuesWithLabel(String label, String state) async => [
    for (final b in boxes.values)
      if (_visible(b, label)) _toIssue(b),
  ];

  bool _visible(Box b, String label) {
    if (b.open && b.labels.contains(label)) return true;
    // One stale read after close: the issue still appears as ready once.
    if (label == 'ready-for-agent' && _staleOnce.remove(b.number)) return true;
    return false;
  }

  @override
  Future<String> issueState(int number) async =>
      (boxes[number]?.open ?? false) ? 'OPEN' : 'CLOSED';

  @override
  Future<String> issueTitle(int number) async =>
      boxes[number]?.title ?? 'prd-$number';

  @override
  Future<String> issueComments(int number) async => '';

  @override
  Future<void> closeIssue(int number, String comment) async {
    final b = boxes[number];
    if (b != null) {
      b.open = false;
      b.labels.remove('ready-for-agent');
    }
    _staleOnce.add(number);
    closed.add(number);
  }

  @override
  Future<void> dropAgentLabel(int number) async =>
      boxes[number]?.labels.remove('ready-for-agent');

  @override
  Future<void> relabelForHuman(int number) async {
    final b = boxes[number];
    if (b != null) {
      b.labels.remove('ready-for-agent');
      b.labels.add('ready-for-human');
    }
  }

  @override
  Future<void> commentOnIssue(int number, String body) async {}

  @override
  Future<String?> openPrForBranch(String branch) async => null;

  @override
  Future<String?> createDraftPr({
    required String base,
    required String head,
    required String title,
    required String body,
  }) async => 'pr-$head';

  @override
  Future<void> commentOnPr(String ref, String body) async {}

  @override
  Future<void> markPrReady(String ref) async {}
}

class FakeGit extends GitOps {
  FakeGit({this.drift = false}) : super(ProcessRunner());

  final bool drift;
  final commits = <String>[];

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
  Future<String> currentBranch() async => '280-holdings';
  @override
  Future<bool> hasDrift() async => drift;
  @override
  Future<bool> commitAll(String message) async {
    commits.add(message);
    return true;
  }

  @override
  Future<bool> pushBranch(String branch) async => true;
  @override
  Future<int> aheadOf(String base) async => commits.length;
  @override
  Future<List<String>> localBranches() async => const ['280-holdings'];
  @override
  Future<void> tagFail(int issueNumber) async {}
  @override
  Future<void> resetHard(String ref) async {}
  @override
  Future<List<String>> changedFiles(String baseline) async => const [];
}

class FakeClaude extends ClaudeRunner {
  FakeClaude() : super(ProcessRunner());

  final implemented = <int>[];

  @override
  Future<ClaudeRun> implement({
    required String model,
    required String prompt,
    String systemAppend = '',
  }) async {
    implemented.add(int.parse(prompt.trim()));
    return const ClaudeRun(transcript: '', result: _okResult);
  }

  @override
  Future<ClaudeRun> verify(String prompt) async =>
      const ClaudeRun(transcript: 'VERDICT: PASS', result: _okResult);

  @override
  Future<ClaudeRun> classify(String prompt) async =>
      const ClaudeRun(transcript: 'LANE: normal', result: _okResult);
}

class FakeProc extends ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> arguments) async =>
      const ProcResult(0, '', '');
}

PromptLibrary _prompts() => PromptLibrary(
  implementer: PromptTemplate('implementer', '{{ISSUE_NUMBER}}', const {
    'ISSUE_NUMBER',
  }),
  verifier: PromptTemplate('verifier', 'v', const {}),
  prVerifier: PromptTemplate('pr-verifier', 'p', const {}),
  intake: PromptTemplate('intake', 'i', const {}),
);

const _config = Config(
  repo: 'o/r',
  state: 'open',
  base: 'dev',
  model: 'sonnet',
  dryRun: false,
);

HarnessLoop _loop(StaleGh gh, FakeClaude claude, FakeGit git) => HarnessLoop(
  config: _config,
  gh: gh,
  git: git,
  claude: claude,
  proc: FakeProc(),
  prompts: _prompts(),
  traces: _tempTraces(),
);

void main() {
  test(
    'a closed issue surfacing as a stale read is not re-implemented',
    () async {
      final boxes = {
        280: Box(280, 'Holdings', 'no parent', {'ready-for-agent'}, true),
      };
      final gh = StaleGh(boxes);
      final claude = FakeClaude();

      final code = await _loop(gh, claude, FakeGit(drift: true)).run();

      expect(code, 0);
      expect(claude.implemented, [280]);
      expect(gh.closed, [280]);
    },
  );
}
