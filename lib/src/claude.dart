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

  /// A *transient* API failure the loop can recover from by retrying the same
  /// `claude` run after a backoff — an overloaded/5xx status, a dropped stream
  /// that killed the process before a `result` arrived, or an exhausted internal
  /// API retry. Null when the run is fine or the failure is hard (rate limit,
  /// auth, billing — see [fatalError]).
  String? get transientApiError {
    if (rateLimited != null) return null;
    final r = result;
    if (r == null) {
      return 'claude exited without a result event '
          '(streaming or process failure)';
    }
    if (r.isFatal && r.isTransientApi) return r.errorMessage;
    return null;
  }

  /// A *hard*, unrecoverable condition — rate limit, auth/billing failure —
  /// where every retry would fail the same way, so the loop must abort. A
  /// transient API failure is [transientApiError] instead; a per-task failure
  /// like `error_max_turns` or bad code the gates catch is neither.
  String? get fatalError {
    if (rateLimited != null) return rateLimited!.summary;
    final r = result;
    if (r == null) return null;
    if (r.isFatal && !r.isTransientApi) return r.errorMessage;
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
  ClaudeRunner(this._proc, {Ansi? ansi}) : _ansi = ansi ?? Ansi.forStdout();

  final ProcessRunner _proc;
  final Ansi _ansi;

  Future<ClaudeRun> implement({
    required String model,
    required String prompt,
    String systemAppend = '',
  }) => _run([
    '--model',
    model,
    if (systemAppend.isNotEmpty) ...['--append-system-prompt', systemAppend],
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
    final renderer = StreamRenderer(ansi: _ansi);
    await _proc.stream('claude', arguments, onLine: renderer.onLine);
    return ClaudeRun(
      transcript: renderer.transcript,
      result: renderer.result,
      rateLimited: renderer.rateLimited,
    );
  }
}
