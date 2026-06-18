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
- Restate the acceptance criteria to yourself as a concrete checklist. That checklist is your definition of done.
- Use the Explore agent to locate the relevant code before changing anything — do not guess at file locations.
- If the task touches a domain topic (websocket, streaming, widgets, approval, history, etc.), delegate to the domain-doc-researcher agent first and honor the constraints it returns.
</orient>

<implement>
- Prefer retrieval-led reasoning over pre-training-led reasoning for all Flutter/Dart work: confirm APIs and patterns against the actual code, not from memory.
- Match the conventions of the surrounding code — naming, structure, error handling, and idioms.
- Ship FULL implementations only. NEVER leave placeholders, stubs, TODOs, or commented-out code.
- Write self-documenting code. Add a comment only to explain a non-obvious decision, never to divide a file into sections.
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
  int? chunkIndex,
  int? chunkTotal,
}) {
  final stackNote = chunkIndex == null || chunkTotal == null
      ? 'Judge the PRD as a whole: the slices must fit together with no '
            'contradictions or integration gaps, and satisfy the PRD\'s intent.'
      : 'This PR is chunk $chunkIndex/$chunkTotal of a stacked split of one '
            'PRD; the range is ONLY this chunk\'s slice. Earlier chunks are '
            'already in its base and later chunks build on top, so review just '
            'this slice and do NOT flag incompleteness that a later chunk '
            'resolves (a symbol defined here and used later, a feature '
            'finished in a later chunk).';
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

$stackNote FAIL only for the blocking
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

    test(
      'pr-verifier — a stacked chunk scopes the note to its slice',
      () async {
        final lib = await defaults();
        final out = lib.prVerifier(
          42,
          'My PRD',
          '42-chunk-1-of-3-my-prd',
          repo: 'octo/app',
          prRef: 'https://github.com/octo/app/pull/8',
          chunkIndex: 2,
          chunkTotal: 3,
        );
        expect(
          out.trim(),
          _expectedPrVerifier(
            42,
            'My PRD',
            '42-chunk-1-of-3-my-prd',
            repo: 'octo/app',
            prRef: 'https://github.com/octo/app/pull/8',
            chunkIndex: 2,
            chunkTotal: 3,
          ).trim(),
        );
        // The chunk note replaces the whole-PRD framing and names the slice.
        expect(out, contains('chunk 2/3 of a stacked split'));
        expect(out, isNot(contains('Judge the PRD as a whole')));
        expect(out, contains('origin/42-chunk-1-of-3-my-prd..HEAD'));
      },
    );
  });
}
