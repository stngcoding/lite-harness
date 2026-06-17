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
}
