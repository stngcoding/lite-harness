import 'verdict.dart';

/// Implementer models cheapest → most capable. A slice opens at its lane floor
/// and climbs one rung per failed retry toward the run ceiling (`--model`) — a
/// cheap model takes the first shot, a smarter one is paid for only on a miss.
const modelLadder = ['haiku', 'sonnet', 'opus', 'fable'];

/// The rung each lane opens on. Tiny/normal start on Sonnet (the gate + retry
/// escalation catch the misses); high-risk opens on Opus, where landing it
/// right outweighs the cost.
const laneFloors = <RiskLane, String>{
  RiskLane.tiny: 'sonnet',
  RiskLane.normal: 'sonnet',
  RiskLane.highRisk: 'opus',
};

/// The model for [lane] on a 1-based [attempt]: the lane floor on attempt 1,
/// climbing one [ladder] rung per retry, capped at [ceiling]. A floor above the
/// ceiling clamps down to it (so `--model sonnet` keeps every lane ≤ Sonnet); a
/// [ceiling] off the ladder disables tiering and is returned as-is.
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
