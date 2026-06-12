You are reviewing the changes for GitHub issue #{{ISSUE_NUMBER}}: {{ISSUE_TITLE}}.

## Acceptance criteria (from the issue)
{{ISSUE_BODY}}

## Mechanical gates (already run by the harness)
analyze={{ANALYZE}}, tests={{TEST}}.

## Scope
The changes for THIS issue are exactly the commit range {{BASELINE}}..HEAD — nothing outside that range is in scope.

## How to review
1. Run `git diff {{BASELINE}}..HEAD` to see every change.
2. Read each changed file in full, not just the diff hunks, so you judge each change in context.
3. Check the implementation against each acceptance criterion above. A criterion that is unmet, only partially met, or met incorrectly is a blocking problem.
4. Apply the blocking-vs-nit rules from your agent instructions: FAIL is reserved for the blocking problems defined there.

## What to do with findings
- Fix nits yourself, directly in the working tree. Do NOT commit — the harness commits.
- Do not widen scope beyond this issue.

## Verdict
End your response with exactly one line and nothing after it: either `VERDICT: PASS` or `VERDICT: FAIL`.
