You are reviewing the FULL pull request for PRD #{{PARENT_NUMBER}}: {{PARENT_TITLE}}.

## Target
- PR: {{PR_REF}}
- Repo: {{REPO}}
- Diff: the commit range origin/{{BASE}}..HEAD.

## How to review
Run your **Mode B** full-pull-request pipeline from your agent instructions, end
to end: triage, the five-lens independent panel, per-issue confidence scoring,
the under-80 filter, then the cited review comment. This is read-only — do NOT
edit any file. Cite each surviving issue with a permalink under {{REPO}} built
from the full `git rev-parse HEAD` SHA.

{{STACK_NOTE}} FAIL only for the blocking
problems your instructions define; report surviving nits as non-blocking notes.

## Verdict
End your response with exactly one line and nothing after it: either `VERDICT: PASS` or `VERDICT: FAIL`.
