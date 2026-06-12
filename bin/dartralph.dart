import 'dart:io';

import 'package:args/args.dart';
import 'package:dartralph/dartralph.dart';

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
  ..addOption('model', help: 'Implementer model (default: sonnet, env MODEL).')
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
    model: options['model'] as String? ?? env['MODEL'] ?? 'sonnet',
    dryRun: options['dry-run'] as bool,
    iterations: iterations,
    issueNumber: issueNumber,
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

  print('Repo:  ${config.repo}');
  print('State: ${config.state}');
  print('Base:  ${config.base}');
  print('');

  final loop = HarnessLoop(
    config: config,
    gh: GhCli(proc, config.repo),
    git: GitOps(proc),
    claude: ClaudeRunner(proc, ansi: ansi),
    proc: proc,
    prompts: prompts,
    ansi: ansi,
  );
  exit(await loop.run());
}
