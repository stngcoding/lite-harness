import 'dart:convert';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

String _rollup(List<Map<String, dynamic>> checks, {String? mergeable}) =>
    jsonEncode({'statusCheckRollup': checks, 'mergeable': ?mergeable});

Map<String, dynamic> _check(
  String status,
  String? conclusion, {
  String? detailsUrl,
}) => {
  '__typename': 'CheckRun',
  'status': status,
  'conclusion': conclusion,
  'detailsUrl': ?detailsUrl,
};

void main() {
  group('parseCiStatus', () {
    test('no rollup / empty rollup → none', () {
      expect(parseCiStatus('{}').state, CiState.none);
      expect(parseCiStatus(_rollup(const [])).state, CiState.none);
    });

    test('malformed JSON degrades to none, never throws', () {
      expect(parseCiStatus('not json').state, CiState.none);
      expect(parseCiStatus('[]').state, CiState.none);
    });

    test('all concluded success → passing', () {
      final s = parseCiStatus(
        _rollup([
          _check('COMPLETED', 'SUCCESS'),
          _check('COMPLETED', 'SKIPPED'),
        ]),
      );
      expect(s.state, CiState.passing);
      expect(s.failedRunIds, isEmpty);
    });

    test('any in-progress check → pending (even beside a success)', () {
      final s = parseCiStatus(
        _rollup([_check('COMPLETED', 'SUCCESS'), _check('IN_PROGRESS', null)]),
      );
      expect(s.state, CiState.pending);
    });

    test('pending outranks a known failure (wait for all to settle)', () {
      final s = parseCiStatus(
        _rollup([
          _check('COMPLETED', 'FAILURE', detailsUrl: 'x/actions/runs/9/job/1'),
          _check('QUEUED', null),
        ]),
      );
      expect(s.state, CiState.pending);
    });

    test('a concluded failure with no pending → failing + run ids', () {
      final s = parseCiStatus(
        _rollup([
          _check('COMPLETED', 'SUCCESS'),
          _check(
            'COMPLETED',
            'FAILURE',
            detailsUrl: 'https://github.com/o/r/actions/runs/42/job/7',
          ),
          _check(
            'COMPLETED',
            'TIMED_OUT',
            detailsUrl: 'https://github.com/o/r/actions/runs/42/job/8',
          ),
        ]),
      );
      expect(s.state, CiState.failing);
      expect(s.failedRunIds, [42], reason: 'same run de-duplicated');
    });

    test('legacy StatusContext entries are honored', () {
      final passing = parseCiStatus(
        jsonEncode({
          'statusCheckRollup': [
            {'__typename': 'StatusContext', 'state': 'SUCCESS'},
          ],
        }),
      );
      expect(passing.state, CiState.passing);

      final failing = parseCiStatus(
        jsonEncode({
          'statusCheckRollup': [
            {
              '__typename': 'StatusContext',
              'state': 'FAILURE',
              'targetUrl': 'https://github.com/o/r/actions/runs/5/job/1',
            },
          ],
        }),
      );
      expect(failing.state, CiState.failing);
      expect(failing.failedRunIds, [5]);
    });

    test('mergeable maps MERGEABLE/CONFLICTING/unknown', () {
      CiStatus withMergeable(String? m) => parseCiStatus(
        _rollup([_check('COMPLETED', 'SUCCESS')], mergeable: m),
      );
      expect(withMergeable('MERGEABLE').mergeable, isTrue);
      expect(withMergeable('CONFLICTING').mergeable, isFalse);
      expect(withMergeable('UNKNOWN').mergeable, isNull);
      expect(withMergeable(null).mergeable, isNull);
    });
  });

  group('runIdFromDetailsUrl', () {
    test('extracts the run id from an Actions URL', () {
      expect(
        runIdFromDetailsUrl('https://github.com/o/r/actions/runs/123456/job/9'),
        123456,
      );
    });

    test('null / non-Actions URL → null', () {
      expect(runIdFromDetailsUrl(null), isNull);
      expect(runIdFromDetailsUrl('https://ci.example.com/build/7'), isNull);
    });
  });

  group('ciPollInterval', () {
    test('30s for the first 5 min, 60s to 15 min, 120s after', () {
      expect(ciPollInterval(Duration.zero), const Duration(seconds: 30));
      expect(
        ciPollInterval(const Duration(minutes: 4, seconds: 59)),
        const Duration(seconds: 30),
      );
      expect(
        ciPollInterval(const Duration(minutes: 5)),
        const Duration(seconds: 60),
      );
      expect(
        ciPollInterval(const Duration(minutes: 14)),
        const Duration(seconds: 60),
      );
      expect(
        ciPollInterval(const Duration(minutes: 15)),
        const Duration(seconds: 120),
      );
      expect(
        ciPollInterval(const Duration(hours: 1)),
        const Duration(seconds: 120),
      );
    });
  });
}
