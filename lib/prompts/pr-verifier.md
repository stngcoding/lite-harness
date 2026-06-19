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

Judge the PRD as a whole: the slices must fit together with no contradictions or integration gaps, and satisfy the PRD's intent. FAIL only for the blocking
problems your instructions define; report surviving nits as non-blocking notes.{{RISK}}

## Manual verification (surface, never gate)
Some acceptance criteria cannot be settled from the diff alone — UI/UX, real-device performance, an external-service behavior, or data only visible at runtime. For each such criterion, emit exactly one line BEFORE your `### Code review` comment:

MANUAL: <the criterion restated as one concrete check a human can perform>

These never affect your verdict — they tell the human reviewing this draft PR what still needs eyes. Emit nothing here if every criterion is verifiable from the diff and the gates.

## Verdict
End your response with exactly one line and nothing after it: either `VERDICT: PASS` or `VERDICT: FAIL`.
