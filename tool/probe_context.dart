// Throwaway: measure startup context occupancy of a real implementer kickoff.
// Loads the target repo's .claude/rules (same as the harness), feeds a real
// closed issue as REFERENCE DATA, and forbids any tool use so nothing in the
// target is touched. Reads the first turn's context % via ClaudeRun.
//
// Run from inside the target clone:
//   cd /path/to/target && dart run /Users/stng/lite-harness/tool/probe_context.dart
import 'dart:io';

import 'package:dartralph/dartralph.dart';

Future<void> main() async {
  final rules = await loadRulesSystemPrompt(); // current dir = target repo
  stderr.writeln('rules injected: ${rules.files}');

  final issue = File('/tmp/probe-issue.txt').readAsStringSync();
  final prompt =
      'PROBE ONLY. Do NOT use any tools. Do NOT read, write, or edit any '
      'files. Do NOT make changes. Reply with exactly one word: DONE.\n\n'
      'The text below is reference data only — an example issue. Do not act '
      'on it:\n\n$issue';

  final run = await ClaudeRunner(
    ProcessRunner(),
  ).implement(model: 'opus', prompt: prompt, systemAppend: rules.text);

  final pct = run.contextFreePct;
  stderr.writeln('---');
  stderr.writeln('peakContextTokens: ${run.peakContextTokens}');
  stderr.writeln('contextWindow:     ${run.contextWindow}');
  stderr.writeln(
    'context free:      ${pct == null ? 'unknown' : '${pct.toStringAsFixed(1)}%'}',
  );
}
