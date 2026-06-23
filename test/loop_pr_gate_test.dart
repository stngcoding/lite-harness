import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

/// End-to-end loop regressions reconstructed from the production logs of PRD
/// #367 (`/tmp/dartralph-20260623-185947.log`), which was closed but never
/// PR'd. Two independent defects compounded there, each defended by a distinct
/// fix, so each is exercised in isolation:
///
///  1. The slices declared their parent with an inline **bold** label
///     (`**Parent:** #366`), which the heading-only parser missed. Every slice
///     then self-parented into its own PRD-of-one instead of grouping under the
///     #366 umbrella. `parentOf` now also reads the inline form, so the slices
///     collapse into a single PR. See `the bold-label PRD ships as one PR`.
///
///  2. Because a slice self-parented, the PR gate's `_openSubsOf(self)` counted
///     the just-closed PRD as its own open sub-issue — GitHub's eventually
///     consistent `gh issue list` still returned it for seconds after the close
///     (`open_subs=1 [#367]`). The gate therefore skipped the PR and stranded
///     the branch. A PRD is now structurally excluded from its own sub roster.
///     See `a lagging self-read never blocks the PRD's own PR`.

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
  Box(
    this.number,
    this.title,
    this.body,
    Set<String> labels,
    this.open, {
    this.lagging = false,
  }) : labels = {...labels};

  final int number;
  final String title;
  final String body;
  final Set<String> labels;
  bool open;

  /// Models the worst case of GitHub's eventually-consistent index: once set,
  /// this issue keeps surfacing in `ready-for-agent` list reads even after it
  /// is closed and its label removed, for the rest of the run. This is the lag
  /// that let a drained PRD-of-one read back as its own open sub.
  final bool lagging;
}

Issue _toIssue(Box b) => Issue(
  number: b.number,
  title: b.title,
  body: b.body,
  labels: b.labels.toList(),
  url: 'u/${b.number}',
);

/// A `GhCli` whose issue list is deliberately lagging and which bypasses the
/// real [GhCli]'s read-your-writes overlay (its overrides never call `super`),
/// so the loop's own in-code guards — not the overlay — are what's under test.
class LaggingGh extends GhCli {
  LaggingGh(this.boxes) : super(ProcessRunner(), 'o/r');

  final Map<int, Box> boxes;
  final dropped = <int>[];
  final closed = <int>[];
  final prByBranch = <String, String>{};
  final prBody = <String, String>{};
  final readyMarked = <String>[];
  var prCount = 0;

  @override
  Future<List<Issue>> issuesWithLabel(String label, String state) async => [
    for (final b in boxes.values)
      if (_visible(b, label)) _toIssue(b),
  ];

  bool _visible(Box b, String label) {
    if (b.open && b.labels.contains(label)) return true;
    return label == 'ready-for-agent' && b.lagging;
  }

  @override
  Future<String> issueState(int number) async =>
      (boxes[number]?.open ?? false) ? 'OPEN' : 'CLOSED';

  @override
  Future<String> issueTitle(int number) async =>
      boxes[number]?.title ?? 'prd-$number';

  @override
  Future<String> issueBody(int number) async => boxes[number]?.body ?? '';

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
    prBody[head] = body;
    return prByBranch[head] ??= 'pr-$head';
  }

  @override
  Future<void> commentOnPr(String ref, String body) async {}

  @override
  Future<void> markPrReady(String ref) async => readyMarked.add(ref);

  @override
  Future<void> markPrDraft(String ref) async {}

  @override
  Future<void> closeChunkPrs(int parent) async {}
}

class FakeGit extends GitOps {
  FakeGit({this.drift = false}) : super(ProcessRunner());

  final bool drift;
  final commits = <String>[];
  final _branches = <String>{};
  String _current = 'base';

  @override
  Future<String?> parkDrift() async => null;
  @override
  Future<void> fetch(String base) async {}
  @override
  Future<bool> branchExists(String branch) async => _branches.contains(branch);
  @override
  Future<bool> checkout(String branch) async {
    _current = branch;
    _branches.add(branch);
    return true;
  }

  @override
  Future<bool> checkoutNew(String branch, String from) async {
    _current = branch;
    _branches.add(branch);
    return true;
  }

  @override
  Future<String> head() async => 'BASE';
  @override
  Future<String> currentBranch() async => _current;
  @override
  Future<bool> hasDrift() async => drift;
  @override
  Future<void> stageAll() async {}
  @override
  Future<String> stagedDiff() async => '';
  @override
  Future<bool> commitStaged(String message) async {
    commits.add(message);
    return true;
  }

  @override
  Future<bool> pushBranch(String branch) async => true;
  @override
  Future<int> aheadOf(String base) async => commits.length;
  @override
  Future<List<String>> localBranches() async => _branches.toList();
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
    final n = int.tryParse(prompt.trim());
    if (n != null) implemented.add(n);
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
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async => const ProcResult(0, '', '');
}

PromptLibrary _prompts() => PromptLibrary(
  implementer: PromptTemplate('implementer', '{{ISSUE_NUMBER}}', const {
    'ISSUE_NUMBER',
  }),
  verifier: PromptTemplate('verifier', 'v', const {}),
  prVerifier: PromptTemplate('pr-verifier', 'p', const {}),
  intake: PromptTemplate('intake', 'i', const {}),
  fixer: PromptTemplate('fixer', 'fix {{FINDINGS}}', const {'FINDINGS'}),
  ciFixer: PromptTemplate('ci-fixer', 'ci {{LOGS}}', const {'LOGS'}),
);

const _config = Config(
  repo: 'o/r',
  state: 'open',
  base: 'dev',
  model: 'sonnet',
  dryRun: false,
  concurrency: 1,
  watchCi: false,
);

HarnessLoop _loop(LaggingGh gh, FakeClaude claude, FakeGit git) => HarnessLoop(
  config: _config,
  gh: gh,
  git: git,
  claude: claude,
  proc: FakeProc(),
  prompts: _prompts(),
  traces: _tempTraces(),
);

void main() {
  group('inline bold-label parent grouping (regex fix)', () {
    test('the bold-label PRD ships as exactly one PR, not three', () async {
      // The #366/#367/#368 shape from the logs: an umbrella whose slices declare
      // their parent (and blockers) with inline **bold** labels.
      final boxes = {
        366: Box(366, 'OAuth token refresh', 'PRD spec, no Parent section', {
          'ready-for-agent',
        }, true),
        367: Box(367, 'Slice A', '**Parent:** #366', {'ready-for-agent'}, true),
        368: Box(368, 'Slice B', '**Parent:** #366\n\n**Blocked by:** #367', {
          'ready-for-agent',
        }, true),
      };
      final gh = LaggingGh(boxes);
      final claude = FakeClaude();
      final git = FakeGit(drift: true);

      final code = await _loop(gh, claude, git).run();

      expect(code, 0);
      // Both slices implemented once; the umbrella never is.
      expect(claude.implemented, [367, 368]);
      expect(claude.implemented, isNot(contains(366)));
      // The umbrella is de-queued, never closed (its PR's `Closes #366` does).
      expect(gh.dropped, contains(366));
      expect(boxes[366]!.open, isTrue);
      // The whole PRD ships as a single PR on the umbrella's canonical branch —
      // not one self-parented PRD-of-one per slice.
      expect(gh.prCount, 1);
      expect(gh.prByBranch.keys.single, startsWith('366-'));
      expect(gh.prBody[gh.prByBranch.keys.single], contains('Closes #366'));
      expect(gh.readyMarked.single, startsWith('pr-366-'));
      expect(boxes[367]!.open, isFalse);
      expect(boxes[368]!.open, isFalse);
    });
  });

  group('stale self-read at the PR gate (self-exclude guard)', () {
    test('a lagging self-read never blocks the PRD-of-one own PR', () async {
      // A scattered standalone issue (no parent) whose `gh issue list` index
      // keeps returning it as ready-for-agent after it is closed — the exact
      // `open_subs=1 [#self]` lag that stranded #367. The overlay is bypassed
      // here, so the structural self-exclude guard is the only thing that can
      // keep the PRD from counting itself and skipping its own PR.
      final boxes = {
        500: Box(
          500,
          'Add isPalindrome helper',
          'no parent',
          {'ready-for-agent'},
          true,
          lagging: true,
        ),
      };
      final gh = LaggingGh(boxes);
      final claude = FakeClaude();
      final git = FakeGit(drift: true);

      final code = await _loop(gh, claude, git).run();

      expect(code, 0);
      expect(claude.implemented, [500]);
      expect(gh.closed, [500]);
      // The PR opens despite the lagging self-read — the strand is gone.
      expect(gh.prCount, 1);
      expect(gh.prByBranch.keys.single, startsWith('500-'));
      expect(gh.readyMarked.single, startsWith('pr-500-'));
      // Implemented exactly once: the lag must not re-drive the closed issue.
      expect(claude.implemented, hasLength(1));
    });
  });
}
