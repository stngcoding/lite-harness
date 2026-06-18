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
  final prBase = <String, String>{};
  final prBody = <String, String>{};
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
    prBase[head] = base;
    prBody[head] = body;
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
  FakeGit({
    this.drift = false,
    this.defaultDelta = 10,
    Map<String, int>? deltas,
    List<String>? branches,
  }) : deltas = deltas ?? const {},
       _branches = branches,
       super(ProcessRunner());

  final bool drift;

  /// Per-commit line delta `commitLog` reports; SHAs default to [defaultDelta].
  final int defaultDelta;
  final Map<String, int> deltas;
  final List<String>? _branches;
  final commits = <String>[];
  final carved = <String>[];
  String _current = '263-prd';

  @override
  Future<String?> parkDrift() async => null;
  @override
  Future<void> fetch(String base) async {}
  @override
  Future<bool> branchExists(String branch) async => false;
  @override
  Future<bool> checkout(String branch) async {
    _current = branch;
    return true;
  }

  @override
  Future<bool> checkoutNew(String branch, String from) async {
    _current = branch;
    return true;
  }

  @override
  Future<bool> checkoutNewAt(String branch, String sha) async {
    carved.add(branch);
    _current = branch;
    return true;
  }

  @override
  Future<String> head() async => 'BASE';
  @override
  Future<String> currentBranch() async => _current;
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
  Future<List<String>> commitLog(String base) async => [
    for (var i = 0; i < commits.length; i++) 'c$i',
  ];
  @override
  Future<int> diffLineDelta(String from, String to) async =>
      deltas[to] ?? defaultDelta;
  @override
  Future<List<String>> localBranches() async => _branches ?? const ['263-prd'];
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
    String systemAppend = '',
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

  group('PR splitting', () {
    Map<int, Box> threeSlices() => {
      263: Box(263, 'PRD', '', {'ready-for-agent'}, true),
      264: Box(264, 'Slice1', '## Parent\n#263\n', {'ready-for-agent'}, true),
      265: Box(265, 'Slice2', '## Parent\n#263\n\n## Blocked by\n#264\n', {
        'ready-for-agent',
      }, true),
      266: Box(266, 'Slice3', '## Parent\n#263\n\n## Blocked by\n#265\n', {
        'ready-for-agent',
      }, true),
    };

    test('large PRD opens a chain of stacked PRs, only the last Closes the '
        'parent', () async {
      final gh = FakeGh(threeSlices());
      final claude = FakeClaude();
      // 3 slices × 500 lines each > 800 → one commit per chunk.
      final git = FakeGit(drift: true, defaultDelta: 500);

      final code = await _loop(gh, claude, git).run();

      expect(code, 0);
      expect(claude.implemented, [264, 265, 266]);
      expect(gh.prCount, 3);
      // Bases chain: dev → chunk1 → chunk2 → canonical.
      expect(gh.prBase['263-chunk-1-of-3-prd'], 'dev');
      expect(gh.prBase['263-chunk-2-of-3-prd'], '263-chunk-1-of-3-prd');
      expect(gh.prBase['263-prd'], '263-chunk-2-of-3-prd');
      // Only the final (canonical) PR closes the parent.
      expect(gh.prBody['263-prd'], contains('Closes #263'));
      expect(gh.prBody['263-chunk-1-of-3-prd'], isNot(contains('Closes')));
      expect(gh.prBody['263-chunk-2-of-3-prd'], isNot(contains('Closes')));
      // Each chunk PR is reviewed over its own slice; every PR is marked ready.
      expect(claude.verifyCount, 3);
      expect(
        gh.readyMarked,
        containsAll(<String>[
          'pr-263-chunk-1-of-3-prd',
          'pr-263-chunk-2-of-3-prd',
          'pr-263-prd',
        ]),
      );
    });

    test('a small PRD stays a single PR (no split)', () async {
      final boxes = {
        263: Box(263, 'PRD', '', {'ready-for-agent'}, true),
        264: Box(264, 'Slice1', '## Parent\n#263\n', {'ready-for-agent'}, true),
        265: Box(265, 'Slice2', '## Parent\n#263\n\n## Blocked by\n#264\n', {
          'ready-for-agent',
        }, true),
      };
      final gh = FakeGh(boxes);
      // 2 × 100 = 200 lines < 800 → no split.
      final git = FakeGit(drift: true, defaultDelta: 100);

      await _loop(gh, FakeClaude(), git).run();

      expect(gh.prCount, 1);
      expect(gh.prByBranch.keys, contains('263-prd'));
      expect(gh.prBody['263-prd'], contains('Closes #263'));
      expect(git.carved, isEmpty);
    });

    test('an oversized single slice becomes its own chunk', () async {
      final boxes = {
        263: Box(263, 'PRD', '', {'ready-for-agent'}, true),
        264: Box(264, 'Slice1', '## Parent\n#263\n', {'ready-for-agent'}, true),
        265: Box(265, 'Slice2', '## Parent\n#263\n\n## Blocked by\n#264\n', {
          'ready-for-agent',
        }, true),
      };
      final gh = FakeGh(boxes);
      // First commit alone exceeds the threshold; it is isolated in chunk 1.
      final git = FakeGit(
        drift: true,
        defaultDelta: 50,
        deltas: const {'c0': 900},
      );

      await _loop(gh, FakeClaude(), git).run();

      expect(gh.prCount, 2);
      expect(git.carved, contains('263-chunk-1-of-2-prd'));
      expect(gh.prBase['263-chunk-1-of-2-prd'], 'dev');
      expect(gh.prBase['263-prd'], '263-chunk-1-of-2-prd');
      expect(gh.prBody['263-prd'], contains('Closes #263'));
    });

    test('re-run reuses chunks that already have a PR (idempotent)', () async {
      final gh = FakeGh(threeSlices());
      // Simulate a prior run that already opened chunk 1's PR.
      gh.prByBranch['263-chunk-1-of-3-prd'] = 'old-1';
      final git = FakeGit(drift: true, defaultDelta: 500);

      await _loop(gh, FakeClaude(), git).run();

      // Only the two missing chunks get a fresh createDraftPr.
      expect(gh.prCount, 2);
      expect(git.carved, isNot(contains('263-chunk-1-of-3-prd')));
      expect(gh.prBase['263-chunk-2-of-3-prd'], '263-chunk-1-of-3-prd');
      expect(gh.readyMarked, contains('old-1'));
    });

    test(
      'stranded sweep prefers the canonical branch over a chunk branch',
      () async {
        // Parent open, no ready slices, branch never PR'd → stranded. Both the
        // canonical and a leftover chunk branch exist locally.
        final gh = FakeGh({263: Box(263, 'PRD', '', <String>{}, true)});
        final git = FakeGit(
          drift: true,
          defaultDelta: 500,
          branches: const ['263-chunk-1-of-2-prd', '263-prd'],
        )..commits.addAll(['a', 'b', 'c']);

        await _loop(gh, FakeClaude(), git).run();

        // _maybeOpenPr ran on the canonical branch (slug 'prd'), so the stack is
        // named correctly and the closing PR is the canonical one.
        expect(gh.prBase.containsKey('263-prd'), isTrue);
        expect(gh.prBody['263-prd'], contains('Closes #263'));
        expect(git.carved, contains('263-chunk-1-of-3-prd'));
      },
    );
  });
}
