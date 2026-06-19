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

class FakeGh extends GhCli {
  FakeGh(this.boxes) : super(ProcessRunner(), 'o/r');

  final Map<int, Box> boxes;
  final dropped = <int>[];
  final closed = <int>[];
  final prByBranch = <String, String>{};
  final prBase = <String, String>{};
  final prBody = <String, String>{};
  final readyMarked = <String>[];
  final draftMarked = <String>[];
  final closedChunkPrs = <int>[];
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

  @override
  Future<void> markPrDraft(String ref) async {
    draftMarked.add(ref);
  }

  @override
  Future<void> closeChunkPrs(int parent) async {
    closedChunkPrs.add(parent);
  }
}

class FakeGit extends GitOps {
  FakeGit({this.drift = false, List<String>? branches})
    : _branches = branches,
      super(ProcessRunner());

  final bool drift;

  final List<String>? _branches;
  final commits = <String>[];
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
  var fixCount = 0;

  /// The verdict the PR review emits once any [failFirstReviews] window has
  /// elapsed. `false` → a standing `VERDICT: FAIL` that drives the PRD to draft.
  bool verifyPass = true;

  /// The first N PR reviews emit `VERDICT: FAIL` regardless of [verifyPass];
  /// review N+1 onward uses [verifyPass]. Drives the WS2 auto-fix loop: a few
  /// failing rounds, then (optionally) a pass.
  int failFirstReviews = 0;

  @override
  Future<ClaudeRun> implement({
    required String model,
    required String prompt,
    String systemAppend = '',
  }) async {
    // The implementer template renders to a bare issue number; the fixer renders
    // to `fix <findings>`. Tell them apart so a fix round is not parsed as one.
    final n = int.tryParse(prompt.trim());
    if (n != null) {
      implemented.add(n);
    } else {
      fixCount++;
    }
    return const ClaudeRun(transcript: '', result: _okResult);
  }

  @override
  Future<ClaudeRun> verify(String prompt) async {
    verifyCount++;
    final pass = verifyCount <= failFirstReviews ? false : verifyPass;
    return ClaudeRun(
      transcript: pass ? 'VERDICT: PASS' : 'VERDICT: FAIL',
      result: _okResult,
    );
  }

  var classifyCount = 0;

  /// When false, intake emits no `LANE:` line, so the loop must retry the
  /// classification once before defaulting the lane to normal.
  bool classifyEmitsLane = true;

  @override
  Future<ClaudeRun> classify(String prompt) async {
    classifyCount++;
    return ClaudeRun(
      transcript: classifyEmitsLane ? 'LANE: normal' : 'no lane here',
      result: _okResult,
    );
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
  intake: PromptTemplate('intake', 'i', const {}),
  fixer: PromptTemplate('fixer', 'fix {{FINDINGS}}', const {'FINDINGS'}),
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
  TraceStore? traces,
}) => HarnessLoop(
  config: _config,
  gh: gh,
  git: git,
  claude: claude,
  proc: FakeProc(),
  prompts: _prompts(),
  events: events,
  traces: traces ?? _tempTraces(),
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
      // Review runs over the whole diff before any PR is opened; a green
      // verdict then opens the PR and marks it ready.
      expect(names, containsAllInOrder(['PR_REVIEW', 'PR_OPEN', 'PR_READY']));
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

  group('single PR per PRD (no split)', () {
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

    test('a large PRD opens exactly one PR on the canonical branch', () async {
      final gh = FakeGh(threeSlices());
      final claude = FakeClaude();
      final git = FakeGit(drift: true);

      final code = await _loop(gh, claude, git).run();

      expect(code, 0);
      expect(claude.implemented, [264, 265, 266]);
      // No split: one whole-PRD PR that closes the parent, marked ready once.
      expect(gh.prCount, 1);
      expect(gh.prByBranch.keys, contains('263-prd'));
      expect(gh.prBody['263-prd'], contains('Closes #263'));
      expect(gh.prBase['263-prd'], 'dev');
      expect(claude.verifyCount, 1);
      expect(gh.readyMarked, ['pr-263-prd']);
      // Leftover chunk PRs from an older split run are swept on the way.
      expect(gh.closedChunkPrs, contains(263));
    });

    test('a standing red review exhausts the auto-fix rounds, then drafts the '
        'one PR', () async {
      final gh = FakeGh(threeSlices());
      final claude = FakeClaude()..verifyPass = false;
      final git = FakeGit(drift: true);

      final code = await _loop(gh, claude, git).run();

      expect(code, 0);
      // Initial review + one re-review per fix round (maxReviewFixes = 3).
      expect(claude.verifyCount, 1 + _config.maxReviewFixes);
      expect(claude.fixCount, _config.maxReviewFixes);
      // Still one PR, never a second; left as a draft for a human.
      expect(gh.prCount, 1);
      expect(gh.prByBranch.keys, contains('263-prd'));
      expect(gh.readyMarked, isEmpty);
      expect(gh.draftMarked, ['pr-263-prd']);
    });

    test('auto-fix recovers a failed review → the one PR goes ready', () async {
      final gh = FakeGh(threeSlices());
      // First review FAILs, the fixer runs once, the re-review PASSes.
      final claude = FakeClaude()..failFirstReviews = 1;
      final git = FakeGit(drift: true);

      final code = await _loop(gh, claude, git).run();

      expect(code, 0);
      expect(claude.verifyCount, 2); // initial fail + one passing re-review
      expect(claude.fixCount, 1); // exactly one fix round
      expect(gh.prCount, 1);
      expect(gh.readyMarked, ['pr-263-prd']);
      expect(gh.draftMarked, isEmpty);
    });

    test('a re-run reuses the existing canonical PR (idempotent)', () async {
      final gh = FakeGh(threeSlices());
      // A prior run already opened the PRD's one PR.
      gh.prByBranch['263-prd'] = 'old-263';
      final git = FakeGit(drift: true);

      await _loop(gh, FakeClaude(), git).run();

      // No fresh createDraftPr — the existing PR is updated and marked ready.
      expect(gh.prCount, 0);
      expect(gh.readyMarked, ['old-263']);
    });

    test('stranded sweep ignores leftover chunk branches', () async {
      // Parent open, no ready slices, branch never PR'd → stranded. A leftover
      // chunk branch sits beside the canonical one; only the canonical is PR'd.
      final gh = FakeGh({263: Box(263, 'PRD', '', <String>{}, true)});
      final git = FakeGit(
        drift: true,
        branches: const ['263-chunk-1-of-2-prd', '263-prd'],
      )..commits.addAll(['a', 'b', 'c']);

      await _loop(gh, FakeClaude(), git).run();

      expect(gh.prByBranch.keys, contains('263-prd'));
      expect(gh.prByBranch.keys, isNot(contains('263-chunk-1-of-2-prd')));
      expect(gh.prBody['263-prd'], contains('Closes #263'));
    });
  });

  group('intake retry + classifyFail denoise (WS4)', () {
    test('a null lane retries intake once; a passing slice logs no '
        'classifyFail', () async {
      final boxes = {
        10: Box(10, 'solo', 'no parent here', {'ready-for-agent'}, true),
      };
      final gh = FakeGh(boxes);
      // Intake emits no LANE line, forcing the one retry, then the lane defaults.
      final claude = FakeClaude()..classifyEmitsLane = false;
      final traces = _tempTraces();

      await _loop(gh, claude, FakeGit(drift: true), traces: traces).run();

      // First classify emitted no lane → retried exactly once.
      expect(claude.classifyCount, 2);

      final slice = traces.readAll().firstWhere((r) => r.issue == 10);
      expect(slice.outcome, 'pass');
      // No lane parsed even after the retry → defaulted to normal.
      expect(slice.lane, RiskLane.normal);
      // Denoise: a missing lane on a slice that still PASSed is not friction.
      expect(slice.frictions, isNot(contains(FrictionKind.classifyFail)));
    });

    test('a lane on the first try means no retry', () async {
      final boxes = {
        10: Box(10, 'solo', 'no parent here', {'ready-for-agent'}, true),
      };
      final gh = FakeGh(boxes);
      final claude = FakeClaude(); // classifyEmitsLane defaults to true
      final traces = _tempTraces();

      await _loop(gh, claude, FakeGit(drift: true), traces: traces).run();

      expect(
        claude.classifyCount,
        1,
        reason: 'lane parsed first try, no retry',
      );
      final slice = traces.readAll().firstWhere((r) => r.issue == 10);
      expect(slice.frictions, isNot(contains(FrictionKind.classifyFail)));
    });
  });
}
