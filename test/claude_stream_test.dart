import 'dart:io';

import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

class _CapturingSink implements IOSink {
  final StringBuffer buffer = StringBuffer();

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('parseStreamJsonLine', () {
    test('extracts assistant text blocks', () {
      final events = parseStreamJsonLine(
        '{"type":"assistant","message":{"content":'
        '[{"type":"text","text":"Hello"}]}}',
      );
      expect(events, hasLength(1));
      expect((events.single as AssistantTextEvent).text, 'Hello');
    });

    test('extracts thinking blocks', () {
      final events = parseStreamJsonLine(
        '{"type":"assistant","message":{"content":'
        '[{"type":"thinking","thinking":"Let me reason"}]}}',
      );
      expect(events, hasLength(1));
      expect((events.single as AssistantThinkingEvent).text, 'Let me reason');
    });

    test('extracts tool_use blocks with a brief input summary', () {
      final events = parseStreamJsonLine(
        '{"type":"assistant","message":{"content":'
        '[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}',
      );
      final tool = events.single as ToolUseEvent;
      expect(tool.name, 'Bash');
      expect(tool.summary, contains('ls -la'));
    });

    test('returns both events when a message mixes text and tool_use', () {
      final events = parseStreamJsonLine(
        '{"type":"assistant","message":{"content":'
        '[{"type":"text","text":"Running"},'
        '{"type":"tool_use","name":"Read","input":{"file_path":"a.dart"}}]}}',
      );
      expect(events, hasLength(2));
    });

    test('ignores non-assistant lines and malformed JSON', () {
      expect(
        parseStreamJsonLine('{"type":"system","subtype":"init"}'),
        isEmpty,
      );
      // A result line with no subtype is not a terminal result event.
      expect(parseStreamJsonLine('{"type":"result","result":"done"}'), isEmpty);
      expect(parseStreamJsonLine('not json at all'), isEmpty);
      expect(parseStreamJsonLine(''), isEmpty);
    });

    test('extracts the terminal result event telemetry', () {
      final events = parseStreamJsonLine(
        '{"type":"result","subtype":"success","is_error":false,'
        '"duration_ms":4769,"num_turns":2,"total_cost_usd":0.0492845,'
        '"permission_denials":[],"terminal_reason":"completed"}',
      );
      final result = events.single as ResultEvent;
      expect(result.subtype, 'success');
      expect(result.isError, isFalse);
      expect(result.numTurns, 2);
      expect(result.durationMs, 4769);
      expect(result.costUsd, closeTo(0.0492845, 1e-9));
      expect(result.permissionDenials, 0);
      expect(result.terminalReason, 'completed');
    });

    test('result summary renders turns, cost, and duration', () {
      final result =
          parseStreamJsonLine(
                '{"type":"result","subtype":"success","is_error":false,'
                '"duration_ms":4769,"num_turns":1,"total_cost_usd":0.0492845,'
                '"permission_denials":[]}',
              ).single
              as ResultEvent;
      expect(result.summary, '1 turn · \$0.0493 · 4.8s');
    });

    test('result summary flags errors and permission denials', () {
      final result =
          parseStreamJsonLine(
                '{"type":"result","subtype":"error_max_turns","is_error":true,'
                '"duration_ms":12000,"num_turns":50,"total_cost_usd":1.5,'
                '"permission_denials":[{"tool":"Bash"}]}',
              ).single
              as ResultEvent;
      expect(result.isError, isTrue);
      expect(result.summary, contains('1 denied'));
      expect(result.summary, contains('✗ error_max_turns'));
    });

    test('truncates long tool input summaries', () {
      final events = parseStreamJsonLine(
        '{"type":"assistant","message":{"content":'
        '[{"type":"tool_use","name":"Write","input":'
        '{"file_path":"x.dart","content":"${'a' * 300}"}}]}}',
      );
      final tool = events.single as ToolUseEvent;
      expect(tool.summary.length, lessThanOrEqualTo(80));
    });

    test('parses a rate_limited event', () {
      final event =
          parseStreamJsonLine(
                '{"type":"rate_limit_event","rate_limit_info":'
                '{"status":"rate_limited","rateLimitType":"five_hour",'
                '"resetsAt":1781164200}}',
              ).single
              as RateLimitEvent;
      expect(event.isLimited, isTrue);
      expect(event.rateLimitType, 'five_hour');
      expect(event.resetsAt, 1781164200);
      expect(event.summary, contains('rate limited'));
    });

    test('an allowed rate_limit_event is not limited', () {
      final event =
          parseStreamJsonLine(
                '{"type":"rate_limit_event","rate_limit_info":'
                '{"status":"allowed"}}',
              ).single
              as RateLimitEvent;
      expect(event.isLimited, isFalse);
    });

    test('parses a system api_retry event', () {
      final event =
          parseStreamJsonLine(
                '{"type":"system","subtype":"api_retry","error":"overloaded",'
                '"attempt":1,"max_retries":3,"error_status":529}',
              ).single
              as ApiRetryEvent;
      expect(event.error, 'overloaded');
      expect(event.attempt, 1);
      expect(event.summary, contains('1/3'));
      expect(event.summary, contains('overloaded'));
    });
  });

  group('ResultEvent.isFatal', () {
    ResultEvent parse(String json) =>
        parseStreamJsonLine(json).single as ResultEvent;

    test('an execution error is fatal and carries the API status + text', () {
      final result = parse(
        '{"type":"result","subtype":"error_during_execution",'
        '"is_error":true,"api_error_status":529,"result":"Overloaded"}',
      );
      expect(result.isFatal, isTrue);
      expect(result.errorMessage, contains('529'));
      expect(result.errorMessage, contains('Overloaded'));
    });

    test('a success carrying an error message (auth/billing) is fatal', () {
      final result = parse(
        '{"type":"result","subtype":"success","is_error":true,'
        '"result":"Not logged in · Please run /login"}',
      );
      expect(result.isFatal, isTrue);
      expect(result.errorMessage, contains('Not logged in'));
    });

    test('max-turns is a per-task failure, not fatal', () {
      final result = parse(
        '{"type":"result","subtype":"error_max_turns","is_error":true}',
      );
      expect(result.isFatal, isFalse);
    });

    test('a clean success is not fatal', () {
      final result = parse(
        '{"type":"result","subtype":"success","is_error":false}',
      );
      expect(result.isFatal, isFalse);
    });
  });

  group('StreamRenderer', () {
    test('displays text blocks in full, unclamped', () {
      final sink = _CapturingSink();
      final renderer = StreamRenderer(
        sink: sink,
        ansi: const Ansi(enabled: false),
      );
      renderer.onLine(
        '{"type":"assistant","message":{"content":'
        '[{"type":"text","text":"l1\\nl2\\nl3\\nl4"}]}}',
      );

      // Every line reaches both the transcript and the terminal — no elision.
      final shown = sink.buffer.toString();
      for (final line in ['l1', 'l2', 'l3', 'l4']) {
        expect(renderer.transcript, contains(line));
        expect(shown, contains(line));
      }
      expect(shown, isNot(contains('more)')));
    });

    test(
      'shows thinking blocks in full but keeps them out of the transcript',
      () {
        final sink = _CapturingSink();
        final renderer = StreamRenderer(
          sink: sink,
          ansi: const Ansi(enabled: false),
        );
        renderer.onLine(
          '{"type":"assistant","message":{"content":'
          '[{"type":"thinking","thinking":"t1\\nt2\\nt3"}]}}',
        );

        final shown = sink.buffer.toString();
        expect(shown, contains('t1'));
        expect(shown, contains('t3'));
        // Reasoning must never pollute the transcript the verdict reads.
        expect(renderer.transcript, isEmpty);
      },
    );
  });
}
