import 'dart:io';

import 'ansi.dart';
import 'claude_stream.dart';
import 'proc.dart';

/// The output of one `claude -p` run: the [transcript] the verdict is read from,
/// plus the terminal [result] telemetry (cost/turns/outcome) for AFK monitoring.
/// [result] is null when the process died before emitting a `result` event.
class ClaudeRun {
  const ClaudeRun({
    required this.transcript,
    this.result,
    this.rateLimited,
    this.peakContextTokens = 0,
    this.contextWindow = 200000,
  });

  final String transcript;
  final ResultEvent? result;
  final RateLimitEvent? rateLimited;

  /// The run's peak context-window occupancy in tokens (0 if none was
  /// reported), and the window it is measured against.
  final int peakContextTokens;
  final int contextWindow;

  /// Context headroom at the agent's peak, as a % of the window — null when no
  /// usage was reported (process died before any `assistant` message). A low
  /// value means it ran close to truncating its own working memory.
  double? get contextFreePct => peakContextTokens == 0
      ? null
      : ((contextWindow - peakContextTokens) / contextWindow * 100)
            .clamp(0, 100)
            .toDouble();

  /// A *transient* API failure the loop can retry after a backoff — an
  /// overloaded/5xx status, a dropped stream that killed the process before a
  /// `result`, or an exhausted internal retry. Null when fine or hard (rate
  /// limit, auth, billing — see [fatalError]).
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

  /// A *hard*, unrecoverable condition — rate limit, auth/billing — where every
  /// retry fails the same, so the loop must abort. A transient failure is
  /// [transientApiError]; a per-task failure (`error_max_turns`, bad code the
  /// gates catch) is neither.
  String? get fatalError {
    if (rateLimited != null) return rateLimited!.summary;
    final r = result;
    if (r == null) return null;
    if (r.isFatal && !r.isTransientApi) return r.errorMessage;
    return null;
  }
}

/// Thrown to unwind the loop when a `claude` run can no longer make progress.
/// Caught at the top of [HarnessLoop.run], which prints [message] and exits.
/// [resumable] splits the two kinds: a usage/rate limit reopens later, so work
/// is checkpointed and the process exits retry-me; auth/billing/streaming is
/// not — re-running fails the same, so it exits hard.
class ClaudeAbort implements Exception {
  ClaudeAbort(this.message, {this.resumable = false});

  final String message;
  final bool resumable;

  @override
  String toString() => 'ClaudeAbort: $message';
}

/// The context window in tokens for [model], turning raw usage into a "% free"
/// figure. Every model the harness targets exposes 200k; the map is the seam
/// for one whose window differs.
int contextWindowFor(String model) => _contextWindows[model] ?? 200000;

const _contextWindows = <String, int>{};

class ClaudeRunner {
  ClaudeRunner(this._proc, {Ansi? ansi, this.workingDirectory, this.logSink})
    : _ansi = ansi ?? Ansi.forStdout();

  final ProcessRunner _proc;
  final Ansi _ansi;

  /// The repo a `claude` run executes in. `null` = the harness cwd; a parallel
  /// worker passes its worktree path so the agent edits that tree in isolation.
  final String? workingDirectory;

  /// When set, the live transcript is written here instead of stdout — a worker
  /// routes its agent output to a per-issue log so the console stays free for
  /// the dashboard.
  final IOSink? logSink;

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
  ], contextWindow: contextWindowFor(model));

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

  Future<ClaudeRun> classify(String prompt) => _run([
    '--agent',
    'intake',
    '--dangerously-skip-permissions',
    '--output-format',
    'stream-json',
    '--verbose',
    '-p',
    prompt,
  ]);

  Future<ClaudeRun> _run(
    List<String> arguments, {
    int contextWindow = 200000,
  }) async {
    final renderer = StreamRenderer(
      sink: logSink,
      // A log *file* is not a terminal: ANSI escapes would be written literally
      // as `\x1B[…m` noise, so render plain there; stdout keeps its styling.
      ansi: logSink == null ? _ansi : const Ansi(enabled: false),
      contextWindow: contextWindow,
    );
    await _proc.stream(
      'claude',
      arguments,
      onLine: renderer.onLine,
      workingDirectory: workingDirectory,
    );
    return ClaudeRun(
      transcript: renderer.transcript,
      result: renderer.result,
      rateLimited: renderer.rateLimited,
      peakContextTokens: renderer.peakContextTokens,
      contextWindow: contextWindow,
    );
  }
}
