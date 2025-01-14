import 'package:dcli_core/dcli_core.dart' as core;
import 'package:path/path.dart' hide equals;
import 'package:pubspec2/pubspec2.dart';
import 'package:pubspec2/src/platform.dart';
import 'package:test/test.dart';

void main() {
  test('platforms ', () async {
    const pubspecString = '''
name: my_test_lib
version: 0.1.0
description: for testing
dependencies: 
  meta: ^1.0.0
  dcli: 1.2.0
platforms: 
  linux: 
  windows: 
  macos: 
''';
    final p = PubSpec.fromYamlString(pubspecString);
    var platform = p.platforms['linux']!;
    expect(platform, const TypeMatcher<Platform>());
    expect(platform.name, equals('linux'));

    platform = p.platforms['windows']!;
    expect(platform, const TypeMatcher<Platform>());
    expect(platform.name, equals('windows'));

    platform = p.platforms['macos']!;
    expect(platform, const TypeMatcher<Platform>());
    expect(platform.name, equals('macos'));

    expect(p.platforms.keys, unorderedEquals(['linux', 'windows', 'macos']));

    await core.withTempDir((tempDir) async {
      await p.save(tempDir);

      final pathToPubspec = join(tempDir, 'pubspec.yaml');

      final lf = core.LineFile(pathToPubspec);
      final content = await lf
          .readAll()
          .reduce((previous, current) => '$previous\n$current');
      expect('$content\n', equals(pubspecString));
    });
  });
}
