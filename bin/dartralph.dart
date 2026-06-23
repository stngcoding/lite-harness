import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dartralph/dartralph.dart';

/// A fresh debug log per run under `/tmp`, e.g. `/tmp/dartralph-20260616-153000.log`.
/// Mirrors the convention of the gate logs (`/tmp/ralph-*.log`).
String _debugLogPath() {
  final n = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${n.year}${p(n.month)}${p(n.day)}-${p(n.hour)}${p(n.minute)}${p(n.second)}';
  return '/tmp/dartralph-$stamp.log';
}

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'repo',
    help: 'GitHub repo as owner/name (default: auto-detected, env REPO).',
  )
  ..addOption(
    'state',
    allowed: ['open', 'closed', 'all'],
    help: 'Issue state filter (default: open, env STATE).',
  )
  ..addOption('base', help: 'PR base branch (default: dev, env BASE).')
  ..addOption(
    'model',
    help:
        'Top implementer model / escalation ceiling (default: opus, env '
        'MODEL). Cheap lanes start on Sonnet and climb toward this on retries; '
        'lowering it caps every lane at or below it.',
  )
  ..addOption(
    'issue',
    abbr: 'n',
    help: 'Process only this issue number, then exit.',
  )
  ..addOption(
    'iteration',
    abbr: 'i',
    help: 'Stop after processing N sub-issues.',
  )
  ..addOption(
    'max-attempts',
    help:
        'Re-implement a failing sub-issue up to N times before handing it to '
        'a human (default: 3, env MAX_ATTEMPTS).',
  )
  ..addOption(
    'review-pr',
    help:
        'Skip the implement loop and only review this PR (number or URL): full '
        'suite + diff-verifier, comment the verdict, mark ready if green.',
  )
  ..addOption(
    'concurrency',
    help:
        'How many sub-issues to implement in parallel, each in its own git '
        'worktree (default: 2, max 4, env CONCURRENCY). 1 = sequential.',
  )
  ..addOption(
    'max-ci-fixes',
    help:
        'After a PR opens, feed its CI failures back to a fixer up to N times '
        'before leaving the PR a draft (default: 3, env MAX_CI_FIXES).',
  )
  ..addOption(
    'ci-timeout',
    help:
        'Minutes to watch a PR\'s CI before leaving it a draft for a human '
        '(default: 30, env CI_TIMEOUT_MINS).',
  )
  ..addFlag(
    'watch-ci',
    defaultsTo: true,
    help:
        'After opening a PR whose local gates + review are green, watch its '
        'remote CI to conclusion and auto-fix failures before marking it ready '
        '(env WATCH_CI=0 to disable). A PR with no CI auto-skips the wait.',
  )
  ..addFlag(
    'once',
    negatable: false,
    help: 'Process exactly one sub-issue, then exit (alias for --iteration 1).',
  )
  ..addFlag(
    'dry-run',
    negatable: false,
    help: 'Print the PRD and sub-issue order without changing anything.',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this usage.');

void _usage(ArgParser parser, IOSink sink) {
  sink.writeln(
    'dartralph — drain a PRD\'s ready-for-agent sub-issues, then PR the '
    'whole PRD.\n\n'
    'Run from inside the target repo clone.\n\n'
    'Usage: dartralph [options]\n\n${parser.usage}',
  );
}

Future<void> main(List<String> arguments) async {
  final debugLogPath = _debugLogPath();
  final logFile = File(debugLogPath)..writeAsStringSync('');
  await runZoned(
    () => _run(arguments, debugLogPath),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
        logFile.writeAsStringSync('$line\n', mode: FileMode.append);
      },
    ),
  );
}

Future<void> _run(List<String> arguments, String debugLogPath) async {
  final parser = _buildParser();
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _usage(parser, stderr);
    exit(64);
  }
  if (options['help'] as bool) {
    _usage(parser, stdout);
    return;
  }

  int? issueNumber;
  final issueArg = options['issue'] as String?;
  if (issueArg != null) {
    issueNumber = int.tryParse(issueArg);
    if (issueNumber == null) {
      stderr.writeln('-n/--issue expects a number, got "$issueArg".');
      exit(64);
    }
  }

  int? iterations;
  final iterationArg = options['iteration'] as String?;
  if (iterationArg != null) {
    iterations = int.tryParse(iterationArg);
    if (iterations == null || iterations < 1) {
      stderr.writeln(
        '-i/--iteration expects a positive integer, got "$iterationArg".',
      );
      exit(64);
    }
  } else if (options['once'] as bool) {
    iterations = 1;
  } else if (issueNumber != null) {
    iterations = 1;
  }

  final env = Platform.environment;
  final maxAttemptsArg =
      options['max-attempts'] as String? ?? env['MAX_ATTEMPTS'];
  var maxAttempts = 3;
  if (maxAttemptsArg != null) {
    final parsed = int.tryParse(maxAttemptsArg);
    if (parsed == null || parsed < 1) {
      stderr.writeln(
        '--max-attempts expects a positive integer, got "$maxAttemptsArg".',
      );
      exit(64);
    }
    maxAttempts = parsed;
  }

  final concurrencyArg =
      options['concurrency'] as String? ?? env['CONCURRENCY'];
  var concurrency = 2;
  if (concurrencyArg != null) {
    final parsed = int.tryParse(concurrencyArg);
    if (parsed == null || parsed < 1 || parsed > 4) {
      stderr.writeln('--concurrency expects 1..4, got "$concurrencyArg".');
      exit(64);
    }
    concurrency = parsed;
  }

  final maxCiFixesArg =
      options['max-ci-fixes'] as String? ?? env['MAX_CI_FIXES'];
  var maxCiFixes = 3;
  if (maxCiFixesArg != null) {
    final parsed = int.tryParse(maxCiFixesArg);
    if (parsed == null || parsed < 0) {
      stderr.writeln(
        '--max-ci-fixes expects a non-negative integer, got "$maxCiFixesArg".',
      );
      exit(64);
    }
    maxCiFixes = parsed;
  }

  final ciTimeoutArg =
      options['ci-timeout'] as String? ?? env['CI_TIMEOUT_MINS'];
  var ciTimeout = const Duration(minutes: 30);
  if (ciTimeoutArg != null) {
    final parsed = int.tryParse(ciTimeoutArg);
    if (parsed == null || parsed < 1) {
      stderr.writeln(
        '--ci-timeout expects a positive integer (minutes), got '
        '"$ciTimeoutArg".',
      );
      exit(64);
    }
    ciTimeout = Duration(minutes: parsed);
  }

  // --watch-ci defaults true; WATCH_CI=0/false disables it without a flag.
  final watchCiEnv = env['WATCH_CI'];
  final watchCi = watchCiEnv == null
      ? options['watch-ci'] as bool
      : !(watchCiEnv == '0' || watchCiEnv.toLowerCase() == 'false');

  final ansi = Ansi.forStdout();
  final proc = ProcessRunner();
  final repo =
      options['repo'] as String? ?? env['REPO'] ?? await GhCli.detectRepo(proc);
  if (repo == null || repo.isEmpty) {
    stderr.writeln(
      'Error: could not detect GitHub repo. '
      'Run inside a clone or pass --repo owner/name.',
    );
    exit(1);
  }

  final config = Config(
    repo: repo,
    state: options['state'] as String? ?? env['STATE'] ?? 'open',
    base: options['base'] as String? ?? env['BASE'] ?? 'dev',
    model: options['model'] as String? ?? env['MODEL'] ?? 'opus',
    dryRun: options['dry-run'] as bool,
    iterations: iterations,
    issueNumber: issueNumber,
    maxAttempts: maxAttempts,
    reviewPr: options['review-pr'] as String?,
    concurrency: concurrency,
    watchCi: watchCi,
    maxCiFixes: maxCiFixes,
    ciTimeout: ciTimeout,
  );

  final PromptLibrary prompts;
  try {
    prompts = await PromptLibrary.load();
  } on PromptError catch (e) {
    stderr.writeln(e);
    exit(78);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(78);
  }

  if (!config.dryRun) {
    final installed = await AgentInstaller().ensureInstalled();
    for (final name in installed) {
      print('Installed $name agent → ${AgentInstaller.pathFor(name)}');
    }
  }

  final rules = await loadRulesSystemPrompt();
  for (final name in rules.files) {
    print('Injecting .claude/rules/$name → implementer system prompt');
  }

  final eventsLogPath = debugLogPath.replaceFirst(
    RegExp(r'\.log$'),
    '-events.log',
  );

  print('Repo:  ${config.repo}');
  print('State: ${config.state}');
  print('Base:  ${config.base}');
  print('Debug log:  $debugLogPath');
  if (!config.dryRun) print('Events log: $eventsLogPath');
  if (!config.dryRun) print('Cost log:   $callLogPath');
  print('');

  final loop = HarnessLoop(
    config: config,
    gh: GhCli(proc, config.repo),
    git: GitOps(proc),
    claude: ClaudeRunner(proc, ansi: ansi),
    proc: proc,
    prompts: prompts,
    rulesSystemPrompt: rules.text,
    events: config.dryRun ? null : EventLog(eventsLogPath),
    ansi: ansi,
  );
  exit(await loop.run());
}
