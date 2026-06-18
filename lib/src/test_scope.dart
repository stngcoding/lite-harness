/// The test files a slice's scoped gate should run, derived from the paths it
/// changed: every changed `test/…_test.dart` plus the mirror `_test.dart` of
/// each changed `lib/…dart`. The caller filters these to the ones that exist.
///
/// Per-issue gates run only this scoped set so a slice is never failed for a
/// test it did not touch (e.g. a pre-existing red test on the base branch). The
/// whole suite still runs once at the PR gate.
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
