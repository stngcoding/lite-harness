# dartralph

Minimal AFK harness: drains a PRD's `ready-for-agent` GitHub sub-issues by
running the `claude` CLI per issue, gates every slice, then opens one PR per
PRD. A Dart port of `legacy/my-ralph.sh`, loosely inspired by
[sandcastle](https://github.com/mattpocock/sandcastle) but single-purpose.

## Flow per PRD (Implement → Review → Close, then PR → Review)

1. Pick the highest-priority *processable* `ready-for-agent` sub-issue; its
   `## Parent` section selects the active PRD (a parent-less issue is its own
   PRD-of-one). An issue is processable when every issue in its
   `## Blocked by` section is closed.
2. Check out branch `<parent#>-<slug>` off `origin/<base>` (resumes if it
   already exists; uncommitted drift is parked in a stash first).
3. For each processable sub-issue of the PRD:
   - **Implement** — `claude -p` with the issue body and comments. The agent
     does not commit and does not self-review; the harness owns both.
   - **Commit immediately** — a precise, recoverable per-issue slice.
   - **Gate** — `fvm flutter analyze` + `fvm flutter test` + an independent
     `claude --agent diff-verifier` run over exactly `baseline..HEAD`. `--agent`
     gives the reviewer a clean context window of its own — it does not inherit
     the target repo's `CLAUDE.md` or skills. The harness ships this agent
     (`lib/agents/diff-verifier.md`) and installs it into the target repo's
     `.claude/agents/` on first run if it is missing.
   - **PASS** → close the sub-issue. **FAIL** → tag the attempt
     (`ralph-fail/<n>`), roll back to baseline, comment with reviewer output
     and log tails, relabel `ready-for-human`.
4. On a clean sweep with real commits: push, open one draft PR to `<base>`,
   run a PR-level `diff-verifier` over the whole diff, and mark the PR ready
   only if that review passes.

## Usage

Run from inside the target repo clone:

```sh
dart run ~/lite-harness/bin/dartralph.dart [options]
```

| Option | Default | Meaning |
|---|---|---|
| `--repo owner/name` | auto-detect (env `REPO`) | Target GitHub repo |
| `--state open\|closed\|all` | `open` (env `STATE`) | Issue state filter |
| `--base <branch>` | `dev` (env `BASE`) | PR base branch |
| `--model <model>` | `opus` (env `MODEL`) | Implementer model |
| `--issue N` | — | Process only issue N, then exit |
| `--once` | off | Process exactly one sub-issue, then exit |
| `--dry-run` | off | Print the PRD and sub-issue order; change nothing |

Compile a standalone binary:

```sh
dart compile exe bin/dartralph.dart -o build/dartralph
```

> A compiled exe cannot read the packaged default prompts (no
> `package_config.json` at runtime). To use the standalone binary, commit the
> three template files under `.dartralph/prompts/` in the target repo (see
> below); the harness reads those directly.

## Customizing prompts

The three prompts the harness sends to `claude` live as editable templates.
By default they are loaded from inside the package, but any target repo can
override them — drop a file at `.dartralph/prompts/<name>.md` and it wins
over the default. Override per-file: provide only the ones you want to change.

| Template | Sent during | Placeholders |
|---|---|---|
| `implementer.md` | implementing a sub-issue | `{{ISSUE_NUMBER}}` `{{ISSUE_TITLE}}` `{{LABELS}}` `{{ISSUE_BODY}}` `{{COMMENTS}}` |
| `verifier.md` | per-issue review gate | `{{ISSUE_NUMBER}}` `{{ISSUE_TITLE}}` `{{ISSUE_BODY}}` `{{BASELINE}}` `{{ANALYZE}}` `{{TEST}}` |
| `pr-verifier.md` | whole-PRD PR review | `{{PARENT_NUMBER}}` `{{PARENT_TITLE}}` `{{BASE}}` |

Placeholders are substituted with `{{NAME}}` text — no shell interpolation.
A template referencing an unknown placeholder fails fast at startup with the
list of allowed names, so a typo never reaches a live run. `{{LABELS}}` and
`{{COMMENTS}}` arrive already framed (or empty) so the template stays simple;
`{{ANALYZE}}`/`{{TEST}}` are `PASS`/`FAIL`.

## Development

```sh
dart pub get
dart test
dart analyze
```

Pure logic (issue parsing, priority scoring, stream-json parsing, verdict
detection) is unit-tested; the `gh`/`git`/`claude` orchestration is thin
untested wrappers by design.
