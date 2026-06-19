import 'dart:convert';
import 'dart:io';

import 'ansi.dart';

sealed class StreamEvent {
  const StreamEvent();
}

class AssistantTextEvent extends StreamEvent {
  const AssistantTextEvent(this.text);

  final String text;
}

/// An extended-thinking block. Shown live in full (it is the agent's reasoning,
/// useful for AFK watchers) but kept OUT of the transcript: the verdict protocol
/// reads the transcript, and a stray `VERDICT:` line in reasoning must never be
/// mistaken for the real verdict.
class AssistantThinkingEvent extends StreamEvent {
  const AssistantThinkingEvent(this.text);

  final String text;
}

class ToolUseEvent extends StreamEvent {
  const ToolUseEvent(this.name, this.summary);

  final String name;
  final String summary;
}

/// The per-turn token usage carried on an `assistant` message. [contextTokens]
/// is how much of the model's context window that turn's request filled —
/// `input_tokens` plus both cache figures (a cache *read* still occupies the
/// window). The peak across a run is the high-water mark of context pressure on
/// the agent: a big injected prompt and a long tool loop both push it up.
class UsageEvent extends StreamEvent {
  const UsageEvent(this.contextTokens);

  final int contextTokens;
}

/// The terminal `result` event a headless `claude -p` run emits once, carrying
/// the run's telemetry. None of this is in the transcript the verdict reads —
/// it is surfaced separately for AFK monitoring (cost, turns, failure mode).
class ResultEvent extends StreamEvent {
  const ResultEvent({
    required this.subtype,
    required this.isError,
    required this.costUsd,
    required this.numTurns,
    required this.durationMs,
    required this.permissionDenials,
    this.terminalReason,
    this.apiErrorStatus,
    this.resultText,
  });

  /// `success`, `error_max_turns`, or `error_during_execution`. The process
  /// exits 0 in every case, so this — not the exit code — is the outcome.
  final String subtype;
  final bool isError;
  final double costUsd;
  final int numTurns;
  final int durationMs;

  /// How many tool calls the permission layer blocked. Non-zero means the agent
  /// silently failed to do something — a load-bearing AFK signal.
  final int permissionDenials;
  final String? terminalReason;

  /// HTTP status of a failed API call (e.g. 401, 402, 529), or null.
  final int? apiErrorStatus;

  /// The final `result` text — for error runs this is the error message itself
  /// (e.g. `Not logged in · Please run /login`).
  final String? resultText;

  /// The run failed in a way the harness cannot recover from by moving to the
  /// next issue — auth, billing, an exhausted API retry, etc. Every subsequent
  /// `claude` call would fail the same way, so the loop should abort. A
  /// per-task failure like `error_max_turns` is deliberately NOT fatal.
  bool get isFatal =>
      subtype == 'error_during_execution' || (isError && subtype == 'success');

  /// Whether a fatal run is *transient* — an error thrown mid-execution (an
  /// exhausted internal API retry) or an overloaded/5xx status — so retrying the
  /// same `claude` run after a backoff can recover. Auth/billing statuses
  /// (401/402/403) are never transient: every retry fails the same way.
  bool get isTransientApi {
    final status = apiErrorStatus;
    if (status == 401 || status == 402 || status == 403) return false;
    if (subtype == 'error_during_execution') return true;
    return status != null && status >= 500;
  }

  /// A human-readable error string for an errored run, e.g.
  /// `error_during_execution [HTTP 529]: Overloaded`.
  String get errorMessage {
    final status = apiErrorStatus == null ? '' : ' [HTTP $apiErrorStatus]';
    final text = resultText?.trim();
    final detail = (text != null && text.isNotEmpty) ? ': $text' : '';
    return '$subtype$status$detail';
  }

  /// One-line AFK summary, e.g. `2 turns · $0.0493 · 4.8s`.
  String get summary {
    final parts = [
      numTurns == 1 ? '1 turn' : '$numTurns turns',
      '\$${costUsd.toStringAsFixed(4)}',
      '${(durationMs / 1000).toStringAsFixed(1)}s',
    ];
    if (permissionDenials > 0) parts.add('$permissionDenials denied');
    if (isError) parts.add('✗ $subtype');
    return parts.join(' · ');
  }
}

/// A `rate_limit_event`. Emitted after each API call; `allowed` is the normal
/// case, `rate_limited` means the run is stalling and every subsequent call
/// will too — a fatal, abort-the-loop condition for AFK runs.
class RateLimitEvent extends StreamEvent {
  const RateLimitEvent({
    required this.status,
    this.rateLimitType,
    this.resetsAt,
  });

  final String status;
  final String? rateLimitType;

  /// Unix timestamp (seconds) when the limit window resets, or null.
  final int? resetsAt;

  bool get isLimited => status == 'rate_limited';

  String get summary {
    final kind = rateLimitType == null ? '' : ' ($rateLimitType)';
    final resets = resetsAt == null ? '' : ' — resets at unix $resetsAt';
    return 'rate limited$kind$resets';
  }
}

/// A `system/api_retry` event: claude hit a transient API failure (overloaded,
/// server error, dropped stream) and is retrying. Shown live so AFK watchers
/// can see streaming hiccups; not fatal on its own (an exhausted retry shows up
/// as an `error_during_execution` result, which is).
class ApiRetryEvent extends StreamEvent {
  const ApiRetryEvent({
    required this.error,
    this.attempt,
    this.maxRetries,
    this.errorStatus,
  });

  final String error;
  final int? attempt;
  final int? maxRetries;
  final int? errorStatus;

  String get summary {
    final n = attempt == null ? '' : ' $attempt/${maxRetries ?? '?'}';
    final status = errorStatus == null ? '' : ' [HTTP $errorStatus]';
    return 'API retry$n: $error$status';
  }
}

const _summaryKeys = [
  'command',
  'file_path',
  'path',
  'pattern',
  'query',
  'url',
  'description',
  'prompt',
];

List<StreamEvent> parseStreamJsonLine(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return const [];
  }
  if (decoded case {
    'type': 'assistant',
    'message': final Map message,
  } when message['content'] is List) {
    final events = <StreamEvent>[
      for (final block in (message['content'] as List))
        ...switch (block) {
          {'type': 'text', 'text': final String text} => [
            AssistantTextEvent(text),
          ],
          {'type': 'thinking', 'thinking': final String text} => [
            AssistantThinkingEvent(text),
          ],
          {'type': 'tool_use', 'name': final String name} => [
            ToolUseEvent(name, _summarizeInput(block['input'])),
          ],
          _ => const <StreamEvent>[],
        },
    ];
    if (message['usage'] case final Map usage) {
      final ctx = _contextTokens(usage);
      if (ctx > 0) events.add(UsageEvent(ctx));
    }
    return events;
  }
  if (decoded case {'type': 'result', 'subtype': final String subtype}) {
    final map = decoded as Map;
    return [
      ResultEvent(
        subtype: subtype,
        isError: map['is_error'] == true,
        costUsd: (map['total_cost_usd'] as num?)?.toDouble() ?? 0,
        numTurns: (map['num_turns'] as num?)?.toInt() ?? 0,
        durationMs: (map['duration_ms'] as num?)?.toInt() ?? 0,
        permissionDenials: (map['permission_denials'] as List?)?.length ?? 0,
        terminalReason: map['terminal_reason'] as String?,
        apiErrorStatus: (map['api_error_status'] as num?)?.toInt(),
        resultText: map['result'] as String?,
      ),
    ];
  }
  if (decoded case {
    'type': 'rate_limit_event',
    'rate_limit_info': final Map info,
  }) {
    return [
      RateLimitEvent(
        status: info['status']?.toString() ?? 'allowed',
        rateLimitType: info['rateLimitType'] as String?,
        resetsAt: (info['resetsAt'] as num?)?.toInt(),
      ),
    ];
  }
  if (decoded case {'type': 'system', 'subtype': 'api_retry'}) {
    final map = decoded as Map;
    return [
      ApiRetryEvent(
        error: map['error']?.toString() ?? 'unknown',
        attempt: (map['attempt'] as num?)?.toInt(),
        maxRetries: (map['max_retries'] as num?)?.toInt(),
        errorStatus: (map['error_status'] as num?)?.toInt(),
      ),
    ];
  }
  return const [];
}

/// The context-window occupancy of a turn from its `usage` map: fresh input
/// plus both cache figures. A cache *read* does not bill full price but still
/// fills the window, so it counts toward the headroom calculation.
int _contextTokens(Map usage) {
  int n(Object? v) => (v as num?)?.toInt() ?? 0;
  return n(usage['input_tokens']) +
      n(usage['cache_read_input_tokens']) +
      n(usage['cache_creation_input_tokens']);
}

String _summarizeInput(Object? input) {
  if (input is! Map || input.isEmpty) return '';
  final key = _summaryKeys.firstWhere(
    (k) => input[k] is String,
    orElse: () => input.keys.first.toString(),
  );
  final value = input[key].toString().replaceAll('\n', ' ');
  return _truncate('$key: $value', 80);
}

String _truncate(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';

class StreamRenderer {
  StreamRenderer({IOSink? sink, Ansi? ansi, this.contextWindow = 200000})
    : _sink = sink ?? stdout,
      _ansi = ansi ?? Ansi.forStdout();

  final IOSink _sink;
  final Ansi _ansi;

  /// The model's context window in tokens, used to render peak usage as a
  /// "% free" headroom figure on the terminal `result` line.
  final int contextWindow;

  final StringBuffer _transcript = StringBuffer();

  String get transcript => _transcript.toString();

  int _peakContextTokens = 0;

  /// The highest context-window occupancy seen across the run (0 if no `usage`
  /// was reported). Lets the caller record how close the agent ran to its
  /// context limit.
  int get peakContextTokens => _peakContextTokens;

  ResultEvent? _result;

  /// The run's terminal telemetry, or null if no `result` event was seen (e.g.
  /// the process died mid-stream).
  ResultEvent? get result => _result;

  RateLimitEvent? _rateLimited;

  /// The first `rate_limited` event seen, if any. The loop treats this as a
  /// fatal, abort-the-loop condition: the quota is exhausted and every
  /// subsequent call will stall too.
  RateLimitEvent? get rateLimited => _rateLimited;

  void onLine(String line) {
    for (final event in parseStreamJsonLine(line)) {
      switch (event) {
        case AssistantTextEvent(:final text):
          _transcript.writeln(text);
          if (text.trim().isNotEmpty) _sink.writeln(text);
        case AssistantThinkingEvent(:final text):
          if (text.trim().isNotEmpty) _sink.writeln(_ansi.dimCyan('💭 $text'));
        case ToolUseEvent(:final name, :final summary):
          final label = summary.isEmpty ? name : '$name — $summary';
          _sink.writeln(_ansi.dimMagenta('  ⚒ $label'));
        case UsageEvent(:final contextTokens):
          if (contextTokens > _peakContextTokens) {
            _peakContextTokens = contextTokens;
          }
        case ResultEvent():
          _result = event;
          final tone = event.isError ? _ansi.red : _ansi.dim;
          _sink.writeln(tone('  └ ${event.summary}${_contextSuffix()}'));
        case ApiRetryEvent():
          _sink.writeln(_ansi.yellow('  ↻ ${event.summary}'));
        case RateLimitEvent():
          if (event.isLimited) {
            _rateLimited ??= event;
            _sink.writeln(_ansi.red('  ⚠ ${event.summary}'));
          }
      }
    }
  }

  /// ` · ctx N% free` from the peak occupancy, or empty when no usage was seen.
  String _contextSuffix() {
    if (_peakContextTokens == 0) return '';
    final free = ((contextWindow - _peakContextTokens) / contextWindow * 100)
        .clamp(0, 100)
        .round();
    return ' · ctx $free% free';
  }
}
