import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

ResultEvent _result(String json) =>
    parseStreamJsonLine(json).single as ResultEvent;

RateLimitEvent _rateLimit(String json) =>
    parseStreamJsonLine(json).single as RateLimitEvent;

void main() {
  group('ClaudeRun.fatalError', () {
    test('is null when the run succeeded', () {
      final run = ClaudeRun(
        transcript: 'VERDICT: PASS',
        result: _result(
          '{"type":"result","subtype":"success","is_error":false}',
        ),
      );
      expect(run.fatalError, isNull);
    });

    test('reports a rate limit', () {
      final run = ClaudeRun(
        transcript: '',
        rateLimited: _rateLimit(
          '{"type":"rate_limit_event","rate_limit_info":'
          '{"status":"rate_limited","rateLimitType":"five_hour"}}',
        ),
      );
      expect(run.fatalError, contains('rate limited'));
    });

    test('a missing result event is transient, not a hard abort', () {
      const run = ClaudeRun(transcript: '');
      expect(run.fatalError, isNull);
      expect(run.transientApiError, contains('without a result'));
    });

    test('an auth-status execution error is hard fatal, not transient', () {
      final run = ClaudeRun(
        transcript: '',
        result: _result(
          '{"type":"result","subtype":"error_during_execution",'
          '"is_error":true,"api_error_status":401,"result":"Unauthorized"}',
        ),
      );
      expect(run.fatalError, contains('Unauthorized'));
      expect(run.transientApiError, isNull);
    });

    test('max-turns is recoverable per-task, not a loop abort', () {
      final run = ClaudeRun(
        transcript: '',
        result: _result(
          '{"type":"result","subtype":"error_max_turns","is_error":true}',
        ),
      );
      expect(run.fatalError, isNull);
      expect(run.transientApiError, isNull);
    });
  });

  group('ClaudeRun.transientApiError', () {
    test('an overloaded execution error is transient', () {
      final run = ClaudeRun(
        transcript: '',
        result: _result(
          '{"type":"result","subtype":"error_during_execution",'
          '"is_error":true,"api_error_status":529,"result":"Overloaded"}',
        ),
      );
      expect(run.transientApiError, contains('Overloaded'));
      expect(run.fatalError, isNull);
    });

    test('a 5xx surfaced via an errored success is transient', () {
      final run = ClaudeRun(
        transcript: '',
        result: _result(
          '{"type":"result","subtype":"success",'
          '"is_error":true,"api_error_status":503}',
        ),
      );
      expect(run.transientApiError, isNotNull);
      expect(run.fatalError, isNull);
    });

    test('a rate limit is hard fatal, never transient', () {
      final run = ClaudeRun(
        transcript: '',
        rateLimited: _rateLimit(
          '{"type":"rate_limit_event","rate_limit_info":'
          '{"status":"rate_limited"}}',
        ),
      );
      expect(run.transientApiError, isNull);
      expect(run.fatalError, contains('rate limited'));
    });
  });
}
