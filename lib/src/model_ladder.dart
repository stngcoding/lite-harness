import 'verdict.dart';

/// Implementer models ordered cheapest → most capable. A slice starts at its
/// risk lane's floor and, on each failed retry, climbs one rung toward the run's
/// ceiling (the `--model` value), so a cheap model takes the first shot and a
/// smarter one is only paid for when a gate actually fails.
const modelLadder = ['haiku', 'sonnet', 'opus', 'fable'];

/// The rung each risk lane opens on. Tiny and normal slices start on Sonnet —
/// the bulk of implement spend moves off Opus while the analyze/test gate plus
/// retry escalation catch the misses; high-risk opens on Opus, where landing it
/// right outweighs the cost.
const laneFloors = <RiskLane, String>{
  RiskLane.tiny: 'sonnet',
  RiskLane.normal: 'sonnet',
  RiskLane.highRisk: 'opus',
};

/// The model the implementer should use for [lane] on a given 1-based [attempt].
///
/// The lane's floor is the first attempt's model; each retry climbs one rung up
/// [ladder], capped at [ceiling] (the run's top model). A lane whose floor sits
/// above the ceiling is clamped down to it, so `--model sonnet` keeps every lane
/// at or below Sonnet. A [ceiling] that is not on the ladder disables tiering —
/// it is returned as-is for every attempt, so an exotic model id still works.
String modelForAttempt(
  RiskLane lane,
  int attempt, {
  String ceiling = 'opus',
  List<String> ladder = modelLadder,
  Map<RiskLane, String> floors = laneFloors,
}) {
  final ceilingIdx = ladder.indexOf(ceiling);
  if (ceilingIdx < 0) return ceiling;
  final rawFloor = ladder.indexOf(floors[lane] ?? ceiling);
  final floorIdx = (rawFloor < 0 ? ceilingIdx : rawFloor).clamp(0, ceilingIdx);
  final rung = (floorIdx + (attempt - 1)).clamp(floorIdx, ceilingIdx);
  return ladder[rung];
}
