class Config {
  const Config({
    required this.repo,
    required this.state,
    required this.base,
    required this.model,
    required this.dryRun,
    this.iterations,
    this.issueNumber,
  });

  final String repo;
  final String state;
  final String base;
  final String model;
  final bool dryRun;

  /// Max sub-issues to process before stopping. null = unlimited.
  final int? iterations;
  final int? issueNumber;
}
