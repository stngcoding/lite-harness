import 'issue.dart';

/// The repo-relative paths a slice is expected to touch — the *exact* diff once
/// it has committed, else a *predicted* set from the issue body. An empty set
/// means "unknown"; callers treat unknown as overlapping every same-PRD sibling,
/// so an unpredictable slice serialises rather than forking off a stale base.
typedef ScopeOf = Set<String> Function(int issue);

/// Repo-relative source/asset paths mentioned in an issue body — the cheap scope
/// predictor. Matches `lib|test|bin|assets/…` tokens ending in a file extension.
/// A body that names none yields the empty "unknown" set, treated conservatively.
final RegExp _pathToken = RegExp(
  r'(?:lib|test|bin|assets)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+',
);

Set<String> predictScope(Issue issue) =>
    _pathToken.allMatches(issue.body).map((m) => m.group(0)!).toSet();

/// For each ready slice, the lower-numbered same-PRD slices whose file-scope it
/// overlaps — its *implicit* blockers, serialising co-editors no `## Blocked by`
/// declared. Scopes overlap when they intersect or either is unknown (empty).
/// Edges point low→high, so the relation is a cycle-free DAG. Pure (no GitHub/git
/// state) so it is unit-testable. The caller must filter out umbrellas first:
/// they never pass, so an edge to one would deadlock its dependents.
Map<int, Set<int>> implicitBlockers(
  List<Issue> ready,
  ScopeOf scope,
  int Function(Issue) prdOf,
) {
  final edges = <int, Set<int>>{};
  for (final b in ready) {
    for (final a in ready) {
      if (a.number >= b.number || prdOf(a) != prdOf(b)) continue;
      final sa = scope(a.number);
      final sb = scope(b.number);
      final overlaps = sa.isEmpty || sb.isEmpty || sa.any(sb.contains);
      if (overlaps) (edges[b.number] ??= <int>{}).add(a.number);
    }
  }
  return edges;
}
