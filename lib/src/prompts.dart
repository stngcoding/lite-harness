import 'dart:io';
import 'dart:isolate';

import 'issue.dart';

/// Thrown when a prompt template references a placeholder the harness does not
/// supply. Raised at load time so a typo never reaches a live `claude` run.
class PromptError implements Exception {
  PromptError(this.name, this.unknown, this.allowed);

  final String name;
  final Set<String> unknown;
  final Set<String> allowed;

  @override
  String toString() {
    final bad = (unknown.toList()..sort()).map((v) => '{{$v}}').join(', ');
    final ok = (allowed.toList()..sort()).map((v) => '{{$v}}').join(', ');
    return 'Prompt "$name" references unknown placeholder(s): $bad.\n'
        'Allowed for this prompt: $ok.';
  }
}

final _placeholder = RegExp(r'\{\{(\w+)\}\}');

/// A single prompt body plus the set of placeholders it is allowed to use.
/// Validation happens in the constructor, so building a template that uses an
/// unsupported placeholder fails fast.
class PromptTemplate {
  PromptTemplate(this.name, this.body, this.allowed) {
    final used = _placeholder.allMatches(body).map((m) => m.group(1)!).toSet();
    final unknown = used.difference(allowed);
    if (unknown.isNotEmpty) throw PromptError(name, unknown, allowed);
  }

  final String name;
  final String body;
  final Set<String> allowed;

  String render(Map<String, String> vars) =>
      body.replaceAllMapped(_placeholder, (m) => vars[m.group(1)] ?? '');
}

/// Resolves and renders the harness's three prompts. Each prompt is loaded
/// from `.dartralph/prompts/<name>.md` in the target repo if present, else
/// from the default shipped inside this package. Construction validates every
/// template, so [load] throwing means a prompt is malformed.
class PromptLibrary {
  PromptLibrary({
    required PromptTemplate implementer,
    required PromptTemplate verifier,
    required PromptTemplate prVerifier,
  }) : _implementer = implementer,
       _verifier = verifier,
       _prVerifier = prVerifier;

  final PromptTemplate _implementer;
  final PromptTemplate _verifier;
  final PromptTemplate _prVerifier;

  static const _implementerVars = {
    'ISSUE_NUMBER',
    'ISSUE_TITLE',
    'LABELS',
    'ISSUE_BODY',
    'COMMENTS',
    'RETRY',
  };
  static const _verifierVars = {
    'ISSUE_NUMBER',
    'ISSUE_TITLE',
    'ISSUE_BODY',
    'BASELINE',
    'ANALYZE',
    'TEST',
  };
  static const _prVerifierVars = {
    'PARENT_NUMBER',
    'PARENT_TITLE',
    'BASE',
    'REPO',
    'PR_REF',
  };

  static Future<PromptLibrary> load({Directory? repoRoot}) async {
    final root = repoRoot ?? Directory.current;
    return PromptLibrary(
      implementer: await _resolve('implementer', root, _implementerVars),
      verifier: await _resolve('verifier', root, _verifierVars),
      prVerifier: await _resolve('pr-verifier', root, _prVerifierVars),
    );
  }

  static Future<PromptTemplate> _resolve(
    String name,
    Directory root,
    Set<String> allowed,
  ) async {
    final override = File('${root.path}/.dartralph/prompts/$name.md');
    final body = await override.exists()
        ? await override.readAsString()
        : await _loadDefault(name);
    return PromptTemplate(name, body, allowed);
  }

  static Future<String> _loadDefault(String name) async {
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:dartralph/prompts/$name.md'),
    );
    if (uri == null) {
      throw StateError(
        'Cannot resolve default prompt "$name" (running as a compiled exe?). '
        'Provide .dartralph/prompts/$name.md in the target repo.',
      );
    }
    return File.fromUri(uri).readAsString();
  }

  String implementer({
    required Issue issue,
    required String comments,
    String retry = '',
  }) {
    final labels = issue.labels.join(', ');
    return _implementer.render({
      'ISSUE_NUMBER': '${issue.number}',
      'ISSUE_TITLE': issue.title,
      'LABELS': labels.isEmpty ? '' : 'Labels: $labels\n',
      'ISSUE_BODY': issue.body.isEmpty
          ? '(no description provided)'
          : issue.body,
      'COMMENTS': comments.isEmpty ? '' : '\n### Comments\n$comments\n',
      'RETRY': retry,
    });
  }

  String verifier(
    Issue issue,
    String baseline, {
    required bool analyzeOk,
    required bool testOk,
  }) => _verifier.render({
    'ISSUE_NUMBER': '${issue.number}',
    'ISSUE_TITLE': issue.title,
    'ISSUE_BODY': issue.body.isEmpty ? '(no description provided)' : issue.body,
    'BASELINE': baseline,
    'ANALYZE': analyzeOk ? 'PASS' : 'FAIL',
    'TEST': testOk ? 'PASS' : 'FAIL',
  });

  String prVerifier(
    int parent,
    String title,
    String base, {
    required String repo,
    required String prRef,
  }) => _prVerifier.render({
    'PARENT_NUMBER': '$parent',
    'PARENT_TITLE': title,
    'BASE': base,
    'REPO': repo,
    'PR_REF': prRef,
  });
}
