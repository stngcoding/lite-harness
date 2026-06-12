import 'ansi.dart';
import 'claude_stream.dart';
import 'proc.dart';

/// The output of one `claude -p` run: the [transcript] the verdict is read from,
/// plus the terminal [result] telemetry (cost/turns/outcome) for AFK monitoring.
/// [result] is null when the process died before emitting a `result` event.
class ClaudeRun {
  const ClaudeRun({required this.transcript, this.result, this.rateLimited});

  final String transcript;
  final ResultEvent? result;
  final RateLimitEvent? rateLimited;

  /// A message describing a condition that makes continuing the loop pointless
  /// — rate limit, auth/billing failure, an exhausted API retry, or a streaming
  /// break that killed the process before a `result` arrived. Null when the run
  /// finished in a way the loop can recover from (success, or a per-task failure
  /// like `error_max_turns` or bad code that the gates catch).
  String? get fatalError {
    if (rateLimited != null) return rateLimited!.summary;
    final r = result;
    if (r == null) {
      return 'claude exited without a result event '
          '(streaming or process failure)';
    }
    if (r.isFatal) return r.errorMessage;
    return null;
  }
}

/// Thrown to unwind the loop when a `claude` run hits an unrecoverable
/// condition (rate limit, auth/billing, streaming death). Caught at the top of
/// [HarnessLoop.run], which prints [message] and exits non-zero.
class ClaudeAbort implements Exception {
  ClaudeAbort(this.message);

  final String message;

  @override
  String toString() => 'ClaudeAbort: $message';
}

class ClaudeRunner {
  ClaudeRunner(this._proc, {Ansi? ansi, this.maxLines = 2})
    : _ansi = ansi ?? Ansi.forStdout();

  final ProcessRunner _proc;
  final Ansi _ansi;

  /// Max lines shown per streamed agent text block (see [StreamRenderer]).
  final int maxLines;

  Future<ClaudeRun> implement({
    required String model,
    required String prompt,
  }) => _run([
    '--model',
    model,
    '--dangerously-skip-permissions',
    '--output-format',
    'stream-json',
    '--verbose',
    '-p',
    prompt,
  ]);

  Future<ClaudeRun> verify(String prompt) => _run([
    '--agent',
    'diff-verifier',
    '--dangerously-skip-permissions',
    '--output-format',
    'stream-json',
    '--verbose',
    '-p',
    prompt,
  ]);

  Future<ClaudeRun> _run(List<String> arguments) async {
    final renderer = StreamRenderer(ansi: _ansi, maxLines: maxLines);
    await _proc.stream('claude', arguments, onLine: renderer.onLine);
    return ClaudeRun(
      transcript: renderer.transcript,
      result: renderer.result,
      rateLimited: renderer.rateLimited,
    );
  }
}
