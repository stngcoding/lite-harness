class Config {
  const Config({
    required this.repo,
    required this.state,
    required this.base,
    required this.model,
    required this.dryRun,
    this.iterations,
    this.issueNumber,
    this.maxAttempts = 3,
    this.maxReviewFixes = 3,
    this.reviewPr,
    this.concurrency = 2,
    this.watchCi = true,
    this.maxCiFixes = 3,
    this.ciTimeout = const Duration(minutes: 30),
  });

  final String repo;
  final String state;
  final String base;

  /// The top implementer model and escalation ceiling (default `opus`). Each
  /// slice opens on its lane floor (Sonnet tiny/normal, Opus high-risk) and
  /// climbs toward this ceiling one rung per failed retry (`model_ladder.dart`);
  /// review/CI fixers run on it directly. Lowering it caps every lane ≤ it.
  final String model;
  final bool dryRun;

  /// Max sub-issues to process before stopping. null = unlimited.
  final int? iterations;
  final int? issueNumber;

  /// How many times a single sub-issue is re-implemented before the harness
  /// gives up and hands it to a human. Each retry feeds the failing analyze /
  /// test logs back to the implementer so it can fix forward.
  final int maxAttempts;

  /// When a PRD's gates are green but the holistic review FAILS, the harness
  /// feeds the blocking findings back to a PRD-level fix agent and re-reviews,
  /// up to this many rounds before leaving the PR a draft for a human.
  final int maxReviewFixes;

  /// When set, the harness skips the whole implement loop and only reviews this
  /// PR (number or URL): check out its head, run the full suite + diff-verifier
  /// over `origin/<pr-base>..HEAD`, comment the verdict, mark ready if green.
  final String? reviewPr;

  /// How many sub-issues run concurrently. `1` keeps the sequential path; `> 1`
  /// activates the worker pool — each issue in its own worktree, scheduled by
  /// its `## Blocked by` DAG. Capped at 4: the binding constraint is the shared
  /// Claude account's rate limit, not CPU.
  final int concurrency;

  /// After a PR opens with local gates + review green, watch its remote CI to
  /// conclusion before marking ready: a local `fvm flutter` build can still fail
  /// the PR's GitHub Actions (different OS, golden/integration suites). False
  /// marks ready off the local verdict; a PR with no checks auto-skips the wait.
  final bool watchCi;

  /// How many times CI failures are fed back to a fixer (commit → re-gate
  /// locally → re-push → re-watch) before the PR is left a draft for a human.
  /// Mirrors `maxReviewFixes` for the review gate.
  final int maxCiFixes;

  /// Overall budget for [watchCi] to reach a verdict. If CI is still pending
  /// past this, the PR is left a draft for a human rather than blocking the
  /// loop indefinitely.
  final Duration ciTimeout;
}
