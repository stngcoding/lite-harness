import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

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

class FakeGh extends GhCli {
  FakeGh(this.boxes) : super(ProcessRunner(), 'o/r');

  final Map<int, Box> boxes;
  final dropped = <int>[];
  final closed = <int>[];
  final prByBranch = <String, String>{};
  final readyMarked = <String>[];
  var prCount = 0;

  @override
  Future<List<Issue>> issuesWithLabel(String label, String state) async => [
    for (final b in boxes.values)
      if (b.open && b.labels.contains(label)) _toIssue(b),
  ];

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
    closed.add(number);
  }

  @override
  Future<void> dropAgentLabel(int number) async {
    boxes[number]?.labels.remove('ready-for-agent');
    dropped.add(number);
  }

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
  Future<String?> openPrForBranch(String branch) async => prByBranch[branch];

  @override
  Future<String?> createDraftPr({
    required String base,
    required String head,
    required String title,
    required String body,
  }) async {
    prCount++;
    return prByBranch[head] ??= 'pr-$head';
  }

  @override
  Future<void> commentOnPr(String ref, String body) async {}

  @override
  Future<void> markPrReady(String ref) async {
    readyMarked.add(ref);
  }
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
  Future<String> currentBranch() async => '263-prd';
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
  Future<List<String>> localBranches() async => const ['263-prd'];
  @override
  Future<void> tagFail(int issueNumber) async {}
  @override
  Future<void> resetHard(String ref) async {}
}

class FakeClaude extends ClaudeRunner {
  FakeClaude() : super(ProcessRunner());

  final implemented = <int>[];
  var verifyCount = 0;

  @override
  Future<ClaudeRun> implement({
    required String model,
    required String prompt,
  }) async {
    implemented.add(int.parse(prompt.trim()));
    return const ClaudeRun(transcript: '', result: _okResult);
  }

  @override
  Future<ClaudeRun> verify(String prompt) async {
    verifyCount++;
    return const ClaudeRun(transcript: 'VERDICT: PASS', result: _okResult);
  }
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
);

const _config = Config(
  repo: 'o/r',
  state: 'open',
  base: 'dev',
  model: 'sonnet',
  dryRun: false,
);

HarnessLoop _loop(
  FakeGh gh,
  FakeClaude claude,
  FakeGit git, {
  EventLog? events,
}) => HarnessLoop(
  config: _config,
  gh: gh,
  git: git,
  claude: claude,
  proc: FakeProc(),
  prompts: _prompts(),
  events: events,
);

void main() {
  group('umbrella PRD is never implemented', () {
    test('parent #263 is skipped + de-queued while its slices run', () async {
      final boxes = {
        263: Box(263, 'PRD', '', {'ready-for-agent'}, true),
        264: Box(264, 'Slice1', '## Parent\n#263\n', {'ready-for-agent'}, true),
        265: Box(265, 'Slice2', '## Parent\n#263\n\n## Blocked by\n#264\n', {
          'ready-for-agent',
        }, true),
      };
      final gh = FakeGh(boxes);
      final claude = FakeClaude();

      final code = await _loop(gh, claude, FakeGit()).run();

      expect(code, 0);
      expect(claude.implemented, [264, 265]);
      expect(claude.implemented, isNot(contains(263)));
      expect(gh.dropped, contains(263));
      expect(boxes[263]!.open, isTrue);
      expect(boxes[263]!.labels, isNot(contains('ready-for-agent')));
      expect(boxes[264]!.open, isFalse);
      expect(boxes[265]!.open, isFalse);
    });

    test('a childless parent-less issue is still implemented', () async {
      final boxes = {
        10: Box(10, 'solo', 'no parent here', {'ready-for-agent'}, true),
      };
      final gh = FakeGh(boxes);
      final claude = FakeClaude();

      await _loop(gh, claude, FakeGit()).run();

      expect(claude.implemented, [10]);
      expect(gh.dropped, isEmpty);
      expect(boxes[10]!.open, isFalse);
    });
  });

  group('full PR flow', () {
    test('slices implemented once, umbrella skipped, exactly one PR', () async {
      final boxes = {
        263: Box(263, 'PRD', '', {'ready-for-agent'}, true),
        264: Box(264, 'Slice1', '## Parent\n#263\n', {'ready-for-agent'}, true),
        265: Box(265, 'Slice2', '## Parent\n#263\n\n## Blocked by\n#264\n', {
          'ready-for-agent',
        }, true),
      };
      final gh = FakeGh(boxes);
      final claude = FakeClaude();
      final git = FakeGit(drift: true);

      final code = await _loop(gh, claude, git).run();

      expect(code, 0);
      expect(claude.implemented, [264, 265]);
      expect(git.commits.length, 2);
      expect(gh.prCount, 1);
      expect(gh.prByBranch.keys, contains('263-prd'));
      expect(claude.verifyCount, 1);
      expect(gh.readyMarked, ['pr-263-prd']);
      expect(gh.dropped, contains(263));
      expect(boxes[263]!.open, isTrue);
      expect(boxes[264]!.open, isFalse);
      expect(boxes[265]!.open, isFalse);
    });

    test('event log records the PRD/issue sequence for the run', () async {
      final boxes = {
        263: Box(263, 'PRD', '', {'ready-for-agent'}, true),
        264: Box(264, 'Slice1', '## Parent\n#263\n', {'ready-for-agent'}, true),
        265: Box(265, 'Slice2', '## Parent\n#263\n\n## Blocked by\n#264\n', {
          'ready-for-agent',
        }, true),
      };
      final dir = Directory.systemTemp.createTempSync('ralph-loop-events');
      addTearDown(() => dir.deleteSync(recursive: true));
      final logPath = '${dir.path}/events.log';

      await _loop(
        FakeGh(boxes),
        FakeClaude(),
        FakeGit(drift: true),
        events: EventLog(logPath),
      ).run();

      final lines = File(
        logPath,
      ).readAsLinesSync().where((l) => l.isNotEmpty).toList();
      final names = lines.map((l) => l.split(' ')[1]).toList();

      expect(names.first, 'START');
      expect(names.last, 'DONE');
      expect(names, contains('UMBRELLA_DROP'));
      expect(names, containsAllInOrder(['IMPLEMENT', 'COMMIT', 'CLOSE']));
      expect(names, containsAllInOrder(['PR_OPEN', 'PR_REVIEW', 'PR_READY']));
      expect(
        lines.firstWhere((l) => l.contains(' UMBRELLA_DROP ')),
        contains('prd=263 issue=263'),
      );
      expect(
        lines.firstWhere((l) => l.contains(' PR_OPEN ')),
        contains('prd=263'),
      );
    });
  });
}
