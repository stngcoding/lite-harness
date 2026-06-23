You are reviewing the FULL pull request for PRD #{{PARENT_NUMBER}}: {{PARENT_TITLE}}.

## Target
- PR: {{PR_REF}}
- Repo: {{REPO}}
- Diff: the commit range origin/{{BASE}}..HEAD.

## How to review
Run your **Mode B** full-pull-request pipeline from your agent instructions, end
to end: triage, the six-lens independent panel (including the whole-diff
structural lens), per-issue confidence scoring, the under-80 filter, then the
cited review comment. This is read-only — do NOT edit any file. Cite each
surviving issue with a permalink under {{REPO}} built from the full
`git rev-parse HEAD` SHA.

Judge the PRD as a whole: the slices must fit together with no contradictions or integration gaps, and satisfy the PRD's intent. FAIL only for the blocking
problems your instructions define; report surviving nits as non-blocking notes.{{RISK}}

## Manual verification (surface, never gate)
Some acceptance criteria cannot be settled from the diff alone — UI/UX, real-device performance, an external-service behavior, or data only visible at runtime. For each such criterion, emit exactly one line BEFORE your `### Code review` comment:

MANUAL: <the criterion restated as one concrete check a human can perform>

These never affect your verdict — they tell the human reviewing this draft PR what still needs eyes. Emit nothing here if every criterion is verifiable from the diff and the gates.

## Maintainability (surface, never gate)
The structural lens sees the whole assembled PRD — the only place to catch logic two slices each reinvented, a branch or wrapper that could collapse, incidental complexity a simpler path removes. Emit each such subjective simplification as one line BEFORE your `### Code review` comment:

STRUCTURAL: <what could disappear and why the result is simpler, in one sentence>

These never affect your verdict — the objective CLAUDE.md-rule violations that *do* gate ride the verdict instead. Emit nothing if there is no simplification worth a human's time.

## Evidence checkpoint (before the verdict)
Before the verdict line, pass over every issue you are about to let FAIL this PR and, for each, name the concrete evidence in the diff that makes it blocking: the exact changed line, the symptom, and why the diff — not a guess about runtime — proves it. A claim you cannot ground in a changed line is not a FAIL: re-cast it as a `MANUAL:` line if it depends on UI/runtime, or drop it if it is mere suspicion. Only diff-grounded issues may decide the verdict.

## Verdict
End your response with exactly one line and nothing after it: either `VERDICT: PASS` or `VERDICT: FAIL`.
