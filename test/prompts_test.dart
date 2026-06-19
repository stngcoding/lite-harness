import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

// Expected renderings of the packaged default prompts. The golden tests assert
// the file-backed prompts reproduce these byte-for-byte (modulo incidental
// leading/trailing whitespace), locking the default prompt text against
// accidental drift while leaving per-repo overrides free to diverge.
String _expectedImplementer(Issue issue, String comments, [String retry = '']) {
  final labels = issue.labels.join(', ');
  final body = issue.body.isEmpty ? '(no description provided)' : issue.body;
  return '''
## GitHub Issue #${issue.number}: ${issue.title}
${labels.isEmpty ? '' : 'Labels: $labels\n'}
$body
${comments.isEmpty ? '' : '\n### Comments\n$comments\n'}
$retry
---
You are an expert Flutter/Dart engineer. Implement the issue above, end to end, so that every acceptance criterion in its description and comments is satisfied. Work the two phases below in order; do not skip a phase.

<orient>
- Read the issue description and every comment. Treat the comments as authoritative refinements of the description where they differ.
- This issue is ONE slice of a larger PRD (see the PRD context and the sibling slices above). Before changing anything, reconcile your slice's shared interfaces — field names and their meaning, route parameters, provider/cubit scopes — with the PRD intent, the sibling slices listed, and the slices already implemented in the codebase. A value the PRD requires to be consistent (e.g. a headline metric) must read the same source field everywhere; an interface a sibling slice will consume must already carry the parameters that slice needs.
- Restate the acceptance criteria to yourself as a concrete checklist. That checklist is your definition of done.
- Use the Explore agent to locate the relevant code before changing anything — do not guess at file locations.
- If the task touches a domain topic (websocket, streaming, widgets, approval, history, etc.), delegate to the domain-doc-researcher agent first and honor the constraints it returns.
</orient>

<implement>
- Prefer retrieval-led reasoning over pre-training-led reasoning for all Flutter/Dart work: confirm APIs and patterns against the actual code, not from memory.
- Match the conventions of the surrounding code — naming, structure, error handling, and idioms.
- Ship FULL implementations only. NEVER leave placeholders, stubs, TODOs, or commented-out code.
- Write self-documenting code. Add a comment only to explain a non-obvious decision, never to divide a file into sections.
- When you gate behavior on a state key — a `listenWhen`/`buildWhen` predicate, a status enum, a sentinel value — handle EVERY branch that key can take, not just the happy path: the error branch and the retry/re-fetch path must be covered too, or the UI silently strands on failure. Match the codebase's emit/update convention (e.g. emit-after-await, or whatever the surrounding cubit/notifier already does); do NOT hardcode an emit helper (like `safeEmit`) the surrounding code does not use.
- Do NOT commit and do NOT run git. The harness commits for you.
- When you believe every acceptance criterion is met, STOP. Do NOT commit and do NOT self-review — the harness commits your slice and runs an independent reviewer over it.
</implement>
''';
}

String _expectedVerifier(
  Issue issue,
  String baseline, {
  required bool analyzeOk,
  required bool testOk,
}) {
  final body = issue.body.isEmpty ? '(no description provided)' : issue.body;
  return '''
You are reviewing the changes for GitHub issue #${issue.number}: ${issue.title}.

## Acceptance criteria (from the issue)
$body

## Mechanical gates (already run by the harness)
analyze=${analyzeOk ? 'PASS' : 'FAIL'}, tests=${testOk ? 'PASS' : 'FAIL'}.

## Scope
The changes for THIS issue are exactly the commit range $baseline..HEAD — nothing outside that range is in scope.

## How to review
1. Run `git diff $baseline..HEAD` to see every change.
2. Read each changed file in full, not just the diff hunks, so you judge each change in context.
3. Check the implementation against each acceptance criterion above. A criterion that is unmet, only partially met, or met incorrectly is a blocking problem.
4. Apply the blocking-vs-nit rules from your agent instructions: FAIL is reserved for the blocking problems defined there.

## What to do with findings
- Fix nits yourself, directly in the working tree. Do NOT commit — the harness commits.
- Do not widen scope beyond this issue.

## Verdict
End your response with exactly one line and nothing after it: either `VERDICT: PASS` or `VERDICT: FAIL`.''';
}

String _expectedPrVerifier(
  int parent,
  String title,
  String base, {
  required String repo,
  required String prRef,
}) {
  return '''
You are reviewing the FULL pull request for PRD #$parent: $title.

## Target
- PR: $prRef
- Repo: $repo
- Diff: the commit range origin/$base..HEAD.

## How to review
Run your **Mode B** full-pull-request pipeline from your agent instructions, end
to end: triage, the five-lens independent panel, per-issue confidence scoring,
the under-80 filter, then the cited review comment. This is read-only — do NOT
edit any file. Cite each surviving issue with a permalink under $repo built
from the full `git rev-parse HEAD` SHA.

Judge the PRD as a whole: the slices must fit together with no contradictions or integration gaps, and satisfy the PRD's intent. FAIL only for the blocking
problems your instructions define; report surviving nits as non-blocking notes.

## Verdict
End your response with exactly one line and nothing after it: either `VERDICT: PASS` or `VERDICT: FAIL`.''';
}

Issue _issue({
  int number = 5,
  String title = 'Add thing',
  List<String> labels = const ['enhancement', 'ready-for-agent'],
  String body = 'Do the thing.',
}) => Issue(
  number: number,
  title: title,
  body: body,
  labels: labels,
  url: 'https://example.test/$number',
);

void main() {
  group('PromptTemplate', () {
    test('substitutes known placeholders', () {
      final t = PromptTemplate('t', 'a {{X}} b {{Y}}', {'X', 'Y'});
      expect(t.render({'X': '1', 'Y': '2'}), 'a 1 b 2');
    });

    test('an allowed-but-unused placeholder is fine', () {
      expect(
        () => PromptTemplate('t', 'just {{X}}', {'X', 'Y'}),
        returnsNormally,
      );
    });

    test('throws PromptError on an unknown placeholder at construction', () {
      expect(
        () => PromptTemplate('impl', 'oops {{ISUE_BODY}}', {'ISSUE_BODY'}),
        throwsA(
          isA<PromptError>()
              .having((e) => e.unknown, 'unknown', {'ISUE_BODY'})
              .having(
                (e) => e.toString(),
                'message',
                contains('{{ISSUE_BODY}}'),
              ),
        ),
      );
    });
  });

  group('PromptLibrary.load resolution', () {
    test(
      'falls back to the packaged defaults when no override exists',
      () async {
        final root = await Directory.systemTemp.createTemp('lh-noprompts');
        addTearDown(() => root.delete(recursive: true));

        final lib = await PromptLibrary.load(repoRoot: root);
        expect(
          lib.implementer(issue: _issue(), comments: ''),
          contains('You are an expert Flutter/Dart engineer'),
        );
      },
    );

    test('a per-file override wins; siblings stay on defaults', () async {
      final root = await Directory.systemTemp.createTemp('lh-override');
      addTearDown(() => root.delete(recursive: true));
      final dir = Directory('${root.path}/.dartralph/prompts')
        ..createSync(recursive: true);
      File(
        '${dir.path}/implementer.md',
      ).writeAsStringSync('CUSTOM {{ISSUE_NUMBER}}');

      final lib = await PromptLibrary.load(repoRoot: root);
      expect(
        lib.implementer(issue: _issue(number: 9), comments: ''),
        'CUSTOM 9',
      );
      // pr-verifier had no override → still the packaged default.
      expect(
        lib.prVerifier(1, 'PRD', 'dev', repo: 'o/r', prRef: 'url'),
        contains('You are reviewing the FULL pull request'),
      );
    });

    test('a malformed override fails fast at load', () async {
      final root = await Directory.systemTemp.createTemp('lh-bad');
      addTearDown(() => root.delete(recursive: true));
      Directory('${root.path}/.dartralph/prompts').createSync(recursive: true);
      File(
        '${root.path}/.dartralph/prompts/verifier.md',
      ).writeAsStringSync('uses {{BOGUS}}');

      expect(
        () => PromptLibrary.load(repoRoot: root),
        throwsA(isA<PromptError>()),
      );
    });
  });

  group('golden: defaults reproduce the legacy prompts', () {
    Future<PromptLibrary> defaults() async {
      final root = await Directory.systemTemp.createTemp('lh-golden');
      addTearDown(() => root.delete(recursive: true));
      return PromptLibrary.load(repoRoot: root);
    }

    test('implementer — populated issue', () async {
      final lib = await defaults();
      final issue = _issue();
      expect(
        lib.implementer(issue: issue, comments: 'looks good').trim(),
        _expectedImplementer(issue, 'looks good').trim(),
      );
    });

    test('implementer — no labels, no body, no comments', () async {
      final lib = await defaults();
      final issue = _issue(labels: const [], body: '');
      final out = lib.implementer(issue: issue, comments: '');
      expect(out.trim(), _expectedImplementer(issue, '').trim());
      expect(out, contains('(no description provided)'));
      expect(out, isNot(contains('Labels:')));
      expect(out, isNot(contains('### Comments')));
    });

    test('implementer — PRD context and sibling roster are injected', () async {
      final lib = await defaults();
      final out = lib.implementer(
        issue: _issue(number: 11),
        comments: '',
        prdContext: '## PRD #9: Parent\n\nThe whole feature.',
        sliceMap: '- #10 Sibling slice',
      );
      // PRD context lands above the issue header; the roster gets its own
      // heading below the comments.
      expect(
        out.indexOf('## PRD #9: Parent'),
        lessThan(out.indexOf('## GitHub Issue #11')),
      );
      expect(out, contains('The whole feature.'));
      expect(
        out,
        contains(
          '### Sibling slices in this PRD (coordinate shared interfaces)',
        ),
      );
      expect(out, contains('- #10 Sibling slice'));
    });

    test('verifier — both gates, populated body', () async {
      final lib = await defaults();
      final issue = _issue();
      expect(
        lib.verifier(issue, 'abc123', analyzeOk: true, testOk: false).trim(),
        _expectedVerifier(
          issue,
          'abc123',
          analyzeOk: true,
          testOk: false,
        ).trim(),
      );
    });

    test('verifier — empty body uses the default text', () async {
      final lib = await defaults();
      final issue = _issue(body: '');
      final out = lib.verifier(issue, 'abc', analyzeOk: false, testOk: true);
      expect(out, contains('(no description provided)'));
      expect(out, contains('analyze=FAIL, tests=PASS'));
    });

    test('pr-verifier', () async {
      final lib = await defaults();
      expect(
        lib
            .prVerifier(
              42,
              'My PRD',
              'dev',
              repo: 'octo/app',
              prRef: 'https://github.com/octo/app/pull/7',
            )
            .trim(),
        _expectedPrVerifier(
          42,
          'My PRD',
          'dev',
          repo: 'octo/app',
          prRef: 'https://github.com/octo/app/pull/7',
        ).trim(),
      );
    });
  });

  group('risk lane', () {
    Future<PromptLibrary> defaults() async {
      final root = await Directory.systemTemp.createTemp('lh-risk');
      addTearDown(() => root.delete(recursive: true));
      return PromptLibrary.load(repoRoot: root);
    }

    test('implementer injects a high-risk block only for high-risk', () async {
      final lib = await defaults();
      final issue = _issue();
      final none = lib.implementer(issue: issue, comments: '');
      expect(none, isNot(contains('<risk')));

      for (final lane in [RiskLane.tiny, RiskLane.normal]) {
        final out = lib.implementer(issue: issue, comments: '', lane: lane);
        expect(out, isNot(contains('<risk')), reason: '$lane adds no block');
      }

      final high = lib.implementer(
        issue: issue,
        comments: '',
        lane: RiskLane.highRisk,
      );
      expect(high, contains('<risk lane="high-risk">'));
      expect(high, contains('HIGH-RISK'));
    });

    test('pr-verifier tightens the bar only for high-risk', () async {
      final lib = await defaults();
      String pr(RiskLane? lane) => lib.prVerifier(
        1,
        'PRD',
        'dev',
        repo: 'o/r',
        prRef: 'url',
        lane: lane,
      );
      for (final lane in [null, RiskLane.tiny, RiskLane.normal]) {
        expect(pr(lane), isNot(contains('HIGH-RISK')));
      }
      expect(pr(RiskLane.highRisk), contains('HIGH-RISK'));
      expect(pr(RiskLane.highRisk), contains('Tighten your bar'));
    });

    test('intake renders the issue and PRD context', () async {
      final lib = await defaults();
      final out = lib.intake(
        issue: _issue(number: 7, title: 'Wire auth'),
        prdContext: '## PRD #3: Login',
      );
      expect(out, contains('## GitHub Issue #7: Wire auth'));
      expect(out, contains('## PRD #3: Login'));
      expect(out, contains('Labels: enhancement, ready-for-agent'));
      expect(out, contains('FLAGS:'));
      expect(out, contains('LANE:'));
    });
  });
}
