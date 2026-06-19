import 'dart:io';
import 'dart:isolate';

import 'issue.dart';
import 'verdict.dart';

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
    required PromptTemplate intake,
  }) : _implementer = implementer,
       _verifier = verifier,
       _prVerifier = prVerifier,
       _intake = intake;

  final PromptTemplate _implementer;
  final PromptTemplate _verifier;
  final PromptTemplate _prVerifier;
  final PromptTemplate _intake;

  static const _implementerVars = {
    'PRD_CONTEXT',
    'SLICE_MAP',
    'ISSUE_NUMBER',
    'ISSUE_TITLE',
    'LABELS',
    'ISSUE_BODY',
    'COMMENTS',
    'RETRY',
    'RISK',
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
    'RISK',
  };
  static const _intakeVars = {
    'PRD_CONTEXT',
    'ISSUE_NUMBER',
    'ISSUE_TITLE',
    'LABELS',
    'ISSUE_BODY',
  };

  static Future<PromptLibrary> load({Directory? repoRoot}) async {
    final root = repoRoot ?? Directory.current;
    return PromptLibrary(
      implementer: await _resolve('implementer', root, _implementerVars),
      verifier: await _resolve('verifier', root, _verifierVars),
      prVerifier: await _resolve('pr-verifier', root, _prVerifierVars),
      intake: await _resolve('intake', root, _intakeVars),
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
    String prdContext = '',
    String sliceMap = '',
    String retry = '',
    RiskLane? lane,
  }) {
    final labels = issue.labels.join(', ');
    return _implementer.render({
      'PRD_CONTEXT': prdContext.isEmpty ? '' : '$prdContext\n\n',
      'SLICE_MAP': sliceMap.isEmpty
          ? ''
          : '\n### Sibling slices in this PRD (coordinate shared interfaces)\n'
                '$sliceMap\n',
      'ISSUE_NUMBER': '${issue.number}',
      'ISSUE_TITLE': issue.title,
      'LABELS': labels.isEmpty ? '' : 'Labels: $labels\n',
      'ISSUE_BODY': issue.body.isEmpty
          ? '(no description provided)'
          : issue.body,
      'COMMENTS': comments.isEmpty ? '' : '\n### Comments\n$comments\n',
      'RETRY': retry,
      'RISK': _implementerRisk(lane),
    });
  }

  /// The risk-lane block injected into the implementer prompt. Only a high-risk
  /// lane raises the bar (the prompt body is already written for the normal
  /// case); tiny and an unclassified (null) lane add nothing, so the placeholder
  /// renders empty and the prompt is byte-for-byte the baseline.
  static String _implementerRisk(RiskLane? lane) => switch (lane) {
    RiskLane.highRisk =>
      '\n<risk lane="high-risk">\n'
          'HIGH-RISK slice (auth, data model / migration, a public contract, '
          'security, an external provider, or existing behavior). Before you '
          'change anything:\n'
          '- Preserve existing public contracts and persisted data shapes: do '
          'NOT rename or repurpose a shared field, route parameter, or '
          'provider/cubit scope a sibling slice or caller depends on.\n'
          '- Keep any interface a sibling slice will consume carrying the '
          'parameters that slice needs.\n'
          '- State every assumption you make explicitly where it is not '
          'obvious.\n'
          '- Add tests that prove the changed behavior, including the edge the '
          'risk points at.\n'
          '</risk>\n',
    RiskLane.tiny || RiskLane.normal || null => '',
  };

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
    RiskLane? lane,
  }) {
    return _prVerifier.render({
      'PARENT_NUMBER': '$parent',
      'PARENT_TITLE': title,
      'BASE': base,
      'REPO': repo,
      'PR_REF': prRef,
      'RISK': _prVerifierRisk(lane),
    });
  }

  /// The risk-lane note injected into the PR reviewer prompt. Only a high-risk
  /// PRD tightens the bar; otherwise the placeholder renders empty so the prompt
  /// is the baseline. Advisory — it steers the reviewer, never blocks the loop.
  static String _prVerifierRisk(RiskLane? lane) => lane != RiskLane.highRisk
      ? ''
      : '\n\nThis PRD is HIGH-RISK (auth, data model / migration, a public '
            'contract, security, or an external provider). Tighten your bar: '
            'verify every contract, auth, and migration claim against the '
            'actual diff, and do NOT PASS on an unverified contract claim — '
            'treat an unproven behavior change as a blocking gap, not a note.';

  String intake({required Issue issue, String prdContext = ''}) {
    final labels = issue.labels.join(', ');
    return _intake.render({
      'PRD_CONTEXT': prdContext.isEmpty ? '' : '$prdContext\n\n',
      'ISSUE_NUMBER': '${issue.number}',
      'ISSUE_TITLE': issue.title,
      'LABELS': labels.isEmpty ? '' : 'Labels: $labels\n',
      'ISSUE_BODY': issue.body.isEmpty
          ? '(no description provided)'
          : issue.body,
    });
  }
}
