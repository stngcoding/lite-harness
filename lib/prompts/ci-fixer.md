## PRD #{{PARENT_NUMBER}}: {{PARENT_TITLE}}

This PRD's PR passed every local gate (analyze + tests) and the independent review, was pushed, and opened — but its **remote CI failed**. The failed-job logs from the PR's CI are below. The local suite is green, so the failure is something CI exercises that the local gates do not: a different OS or toolchain, golden/screenshot tests, an integration or build/codegen step, a stricter analyzer, or a check over files the scoped gates skipped.

### Failed CI logs
```
{{LOGS}}
```

---
You are an expert Flutter/Dart engineer fixing this PRD's PR so its remote CI passes. The implementation already exists in the working tree (the whole PRD diff is `origin/{{BASE}}..HEAD` on the current branch); you are fixing the CI failure on top of it.

<orient>
- Read the logs above as your evidence. Find the FIRST real failure — later errors are often fallout from it. Treat the file/line/check it names as a starting point, then confirm the true root cause against the actual code before changing anything.
- Use the Explore agent to locate the relevant code; review the existing PRD diff (`git diff origin/{{BASE}}..HEAD`) so your fix is coherent with what the slices already built, not a parallel rewrite.
- Reproduce locally when you can: run the specific failing command, test, or codegen step the log shows (e.g. the exact `flutter test path/to/foo_test.dart`, a build_runner step, or a golden update) so you know your fix actually addresses it rather than guessing from the log.
- If the failure is purely an environment/config gap CI enforces (a missing generated file that must be committed, a dependency not pinned, a CI-only flag), fix the root cause in the repo — do not paper over it.
</orient>

<fix>
- Make the SMALLEST correct root-cause fix for the CI failure. Do NOT broaden scope, refactor unrelated code, or weaken/delete a failing check to make it pass — fix what the check is catching.
- Do not regress the local gates: your change must keep `flutter analyze` and the tests green. Preserve the existing public contracts and persisted data shapes the slices established.
- Prefer retrieval-led reasoning: confirm APIs and patterns against the actual code, not from memory. Match the conventions of the surrounding code.
- Ship FULL fixes only. NEVER leave placeholders, stubs, TODOs, or commented-out code.
- Do NOT commit and do NOT run git. The harness commits your fix, re-runs the local gates, re-pushes, and re-watches CI.
- When the CI failure is resolved, STOP.
</fix>
