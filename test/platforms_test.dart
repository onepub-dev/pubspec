import 'package:dcli_core/dcli_core.dart' as core;
import 'package:path/path.dart' hide equals;
import 'package:pubspec2/pubspec2.dart';
import 'package:pubspec2/src/platform.dart';
import 'package:test/test.dart';

void main() {
  test('explicit null platform markers round trip', () {
    final original = PubSpec.fromYamlString('platforms: {linux: null}');
    final encoded = const YamlToString().toYamlString(original.toJson());
    expect(encoded, 'platforms: \n  linux: null\n');
    expect(PubSpec.fromYamlString(encoded).platforms, original.platforms);
  });

  test('platform markers round trip alongside actual empty maps', () {
    final original = PubSpec.fromYamlString('''
name: demo
platforms:
  linux:
  windows:
custom: {}
''');
    final encoded = const YamlToString().toYamlString(original.toJson());
    expect(
        encoded,
        'name: demo\nplatforms: \n  linux: null\n'
        '  windows: null\ncustom: {}\n');
    final reparsed = PubSpec.fromYamlString(encoded);
    expect(reparsed.platforms, original.platforms);
    expect(reparsed.unParsedYaml, {'custom': <String, dynamic>{}});
    expect(original.platforms['linux']!.toJson(), <String, Object>{});
  });

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
      expect(
          '$content\n',
          equals('name: my_test_lib\n'
              "version: '0.1.0'\n"
              'description: for testing\n'
              'dependencies: \n'
              "  meta: '^1.0.0'\n"
              "  dcli: '1.2.0'\n"
              'platforms: \n'
              '  linux: null\n'
              '  windows: null\n'
              '  macos: null\n'));
      expect((await PubSpec.loadFile(pathToPubspec)).platforms, p.platforms);
    });
  });
}
