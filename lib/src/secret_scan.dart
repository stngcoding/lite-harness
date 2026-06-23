/// Pure secret detection over a unified `git diff` — a hard gate before commit:
/// any hit blocks the slice. Only *added* content is scanned (a base secret is
/// out of scope); findings name the rule and file but never the value, so the
/// block message does not re-leak it.
List<String> scanSecrets(String diff) {
  final findings = <String>{};
  String? file;
  var skipFileBody = false;
  for (final line in diff.split('\n')) {
    if (line.startsWith('+++ ')) {
      final path = line.substring(4).trim();
      file = path == '/dev/null'
          ? null
          : path.replaceFirst(RegExp(r'^[ab]/'), '');
      // A tracked secret env file is itself the finding; skip its body so each
      // key does not double-report.
      skipFileBody = file != null && _isEnvSecretFile(file);
      if (skipFileBody) findings.add('committed secret file: $file');
      continue;
    }
    if (skipFileBody) continue;
    if (!line.startsWith('+') || line.startsWith('+++')) continue;
    final added = line.substring(1);
    for (final rule in _rules) {
      if (!rule.pattern.hasMatch(added)) continue;
      if (rule.skipPlaceholders && _placeholder.hasMatch(added)) continue;
      findings.add('${rule.label} in ${file ?? 'diff'}');
    }
  }
  return findings.toList();
}

class _SecretRule {
  const _SecretRule(this.label, this.pattern, {this.skipPlaceholders = false});

  final String label;
  final RegExp pattern;

  /// Whether a placeholder/env-reference suppresses the match — only the
  /// FP-prone generic-credential rule opts in; the specific rules always fire.
  final bool skipPlaceholders;
}

final _rules = <_SecretRule>[
  _SecretRule('AWS access key id', RegExp(r'\bAKIA[0-9A-Z]{16}\b')),
  _SecretRule(
    'private key header',
    RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
  ),
  _SecretRule('provider token', RegExp(r'\bgh[pousr]_[A-Za-z0-9]{36,}\b')),
  _SecretRule(
    'hardcoded credential',
    RegExp(
      r'''(?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*["'][^"']{8,}["']''',
      caseSensitive: false,
    ),
    skipPlaceholders: true,
  ),
];

/// Markers that flag the credential line as a placeholder or an indirection
/// (env var, dotenv, compile-time define) rather than a real embedded secret.
final _placeholder = RegExp(
  r'(xxx|your[_-]|<[^>]+>|\$\{|process\.env|fromEnvironment|dotenv|example|changeme|placeholder|redacted|\*{4,})',
  caseSensitive: false,
);

bool _isEnvSecretFile(String path) {
  final name = path.split('/').last;
  if (name != '.env' && !name.startsWith('.env.')) return false;
  const safeSuffixes = ['.example', '.sample', '.template', '.dist'];
  return !safeSuffixes.any(name.endsWith);
}
