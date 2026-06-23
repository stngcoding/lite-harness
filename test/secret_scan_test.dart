import 'package:dartralph/dartralph.dart';
import 'package:test/test.dart';

void main() {
  test('a clean diff yields no findings', () {
    const diff = '''
+++ b/lib/foo.dart
+import 'bar.dart';
+final greeting = 'hello world';
+void main() => print(greeting);
''';
    expect(scanSecrets(diff), isEmpty);
  });

  test('an added AWS access key id is flagged', () {
    const diff = '''
+++ b/lib/config.dart
+const awsKey = 'AKIAIOSFODNN7EXAMPLE';
''';
    expect(scanSecrets(diff), ['AWS access key id in lib/config.dart']);
  });

  test('an added private key header is flagged', () {
    const diff = '''
+++ b/secrets/key.pem
+-----BEGIN RSA PRIVATE KEY-----
+MIIEpAIBAAKCAQEA...
''';
    expect(
      scanSecrets(diff),
      contains('private key header in secrets/key.pem'),
    );
  });

  test('a hardcoded credential literal is flagged', () {
    const diff = '''
+++ b/lib/api.dart
+final password = "hunter2supersecret";
''';
    expect(scanSecrets(diff), ['hardcoded credential in lib/api.dart']);
  });

  test('an env-var indirection is not a hardcoded credential', () {
    const diff = '''
+++ b/lib/api.dart
+final token = String.fromEnvironment('API_TOKEN');
+final password = "your_password_here";
''';
    expect(scanSecrets(diff), isEmpty);
  });

  test('a committed .env file is flagged once, body not double-counted', () {
    const diff = '''
+++ b/.env
+API_TOKEN=abcd1234efgh5678
+password=anothersecretvalue
''';
    expect(scanSecrets(diff), ['committed secret file: .env']);
  });

  test('a .env.example template is allowed', () {
    const diff = '''
+++ b/.env.example
+API_TOKEN=
+DATABASE_URL=
''';
    expect(scanSecrets(diff), isEmpty);
  });

  test('removed and context lines are ignored', () {
    const diff = '''
+++ b/lib/config.dart
-const awsKey = 'AKIAIOSFODNN7EXAMPLE';
 const other = 'AKIAIOSFODNN7EXAMPLE';
''';
    expect(scanSecrets(diff), isEmpty);
  });
}
