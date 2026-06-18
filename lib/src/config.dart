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
    this.splitThreshold = 800,
    this.reviewPr,
  });

  final String repo;
  final String state;
  final String base;
  final String model;
  final bool dryRun;

  /// Max sub-issues to process before stopping. null = unlimited.
  final int? iterations;
  final int? issueNumber;

  /// How many times a single sub-issue is re-implemented before the harness
  /// gives up and hands it to a human. Each retry feeds the failing analyze /
  /// test logs back to the implementer so it can fix forward.
  final int maxAttempts;

  /// When a PRD's diff exceeds this many changed lines (insertions + deletions),
  /// it is opened as a chain of stacked PRs instead of one — cut at sub-issue
  /// commit boundaries so each PR stays small enough to review comfortably.
  final int splitThreshold;

  /// When set, the harness skips the whole implement loop and only reviews this
  /// PR (number or URL): check out its head, run the full suite + diff-verifier
  /// over `origin/<pr-base>..HEAD`, comment the verdict, mark ready if green.
  final String? reviewPr;
}
