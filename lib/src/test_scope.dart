/// The test files a slice's scoped gate runs, from the paths it changed: every
/// changed `test/…_test.dart` plus the mirror `_test.dart` of each changed
/// `lib/…dart` (caller filters to the ones that exist). Scoping keeps a slice
/// from failing on a test it never touched; the whole suite runs at the PR gate.
Set<String> scopedTestFiles(Iterable<String> changedPaths) {
  final files = <String>{};
  for (final path in changedPaths) {
    if (path.startsWith('test/') && path.endsWith('_test.dart')) {
      files.add(path);
    } else if (path.startsWith('lib/') && path.endsWith('.dart')) {
      final stem = path.substring('lib/'.length, path.length - '.dart'.length);
      files.add('test/${stem}_test.dart');
    }
  }
  return files;
}
