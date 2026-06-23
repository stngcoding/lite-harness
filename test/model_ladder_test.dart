import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('modelForAttempt', () {
    test('tiny/normal open on Sonnet and escalate to Opus on retry', () {
      for (final lane in [RiskLane.tiny, RiskLane.normal]) {
        expect(modelForAttempt(lane, 1), 'sonnet');
        expect(modelForAttempt(lane, 2), 'opus');
        expect(modelForAttempt(lane, 3), 'opus');
      }
    });

    test('high-risk opens on Opus and stays there', () {
      expect(modelForAttempt(RiskLane.highRisk, 1), 'opus');
      expect(modelForAttempt(RiskLane.highRisk, 2), 'opus');
    });

    test('a lower ceiling caps every lane at or below it', () {
      for (final lane in RiskLane.values) {
        expect(modelForAttempt(lane, 1, ceiling: 'sonnet'), 'sonnet');
        expect(modelForAttempt(lane, 3, ceiling: 'sonnet'), 'sonnet');
      }
    });

    test('a ceiling below the lane floor pins the whole lane to it', () {
      for (final lane in RiskLane.values) {
        expect(modelForAttempt(lane, 1, ceiling: 'haiku'), 'haiku');
        expect(modelForAttempt(lane, 2, ceiling: 'haiku'), 'haiku');
      }
    });

    test('a raised ceiling lets escalation climb past Opus', () {
      expect(modelForAttempt(RiskLane.tiny, 1, ceiling: 'fable'), 'sonnet');
      expect(modelForAttempt(RiskLane.tiny, 2, ceiling: 'fable'), 'opus');
      expect(modelForAttempt(RiskLane.tiny, 3, ceiling: 'fable'), 'fable');
      expect(modelForAttempt(RiskLane.highRisk, 2, ceiling: 'fable'), 'fable');
    });

    test('escalation never overshoots the ceiling', () {
      expect(modelForAttempt(RiskLane.tiny, 99), 'opus');
    });

    test('a ceiling not on the ladder disables tiering', () {
      const exotic = 'opus-4-8-20260101';
      expect(modelForAttempt(RiskLane.tiny, 1, ceiling: exotic), exotic);
      expect(modelForAttempt(RiskLane.highRisk, 3, ceiling: exotic), exotic);
    });
  });
}
