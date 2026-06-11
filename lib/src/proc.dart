import 'dart:convert';
import 'dart:io';

class ProcResult {
  const ProcResult(this.code, this.stdout, this.stderr);

  final int code;
  final String stdout;
  final String stderr;

  bool get ok => code == 0;
}

class ProcessRunner {
  Future<ProcResult> run(String executable, List<String> arguments) async {
    final result = await Process.run(executable, arguments);
    return ProcResult(
      result.exitCode,
      result.stdout as String,
      result.stderr as String,
    );
  }

  Future<int> stream(
    String executable,
    List<String> arguments, {
    required void Function(String line) onLine,
  }) async {
    final process = await Process.start(executable, arguments);
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach(stderr.write);
    await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(onLine);
    await stderrDone;
    return process.exitCode;
  }
}
