import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  group('EventLog', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ralph-events-test');
      path = '${dir.path}/events.log';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    List<String> lines() =>
        File(path).readAsLinesSync().where((l) => l.isNotEmpty).toList();

    test('writes one line per event with name, prd, issue and detail', () {
      EventLog(path)
        ..event('START', detail: 'repo=o/r')
        ..event('IMPLEMENT', prd: 1, issue: 2, detail: 'attempt=1/3')
        ..event('CLOSE', prd: 1, issue: 2, detail: 'pass')
        ..event('DONE');

      final logged = lines();
      expect(logged, hasLength(4));
      expect(logged[1], contains(' IMPLEMENT prd=1 issue=2 attempt=1/3'));
      expect(logged[2], contains(' CLOSE prd=1 issue=2 pass'));
      expect(logged[3], endsWith(' DONE'));
    });

    test('omits prd and issue fields when not provided', () {
      EventLog(path).event('PR_OPEN', prd: 7, detail: 'url=x');
      expect(lines().single, contains(' PR_OPEN prd=7 url=x'));
      expect(lines().single, isNot(contains('issue=')));
    });

    test('every line starts with an ISO-8601 timestamp', () {
      EventLog(path).event('START');
      final stamp = lines().single.split(' ').first;
      expect(DateTime.parse(stamp), isA<DateTime>());
    });

    test('truncates the file on construction so it holds one run only', () {
      EventLog(path).event('DONE');
      EventLog(path).event('START');
      expect(lines(), [lines().single]);
      expect(lines().single, endsWith(' START'));
    });
  });
}
