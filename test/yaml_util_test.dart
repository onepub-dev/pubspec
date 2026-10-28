import 'dart:isolate';

import 'package:pubspec2/pubspec2.dart';
import 'package:pubspec2/src/yaml_util.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('normal parsing preserves maps, lists, scalars and consumption', () {
    final parser = parseYaml(loadYaml('''
name: example
metadata:
  values: [hello, 42, 1.5, true, null, [], {}]
  7: numeric key
''') as YamlMap, consumeMap: true);

    expect(parser.single<String, String>('name'), 'example');
    expect(parser.unconsumed, {
      'metadata': {
        'values': [
          'hello',
          42,
          1.5,
          true,
          null,
          <Object?>[],
          <String, Object?>{}
        ],
        '7': 'numeric key'
      }
    });
  });

  test('ordinary scalar, list and mapping aliases retain normal values', () {
    final pubspec = PubSpec.fromYamlString('''
name: &name example
description: *name
metadata:
  base: &base {enabled: true, values: &values [one, 2, null]}
  copy: *base
  lists: [*values, *values]
''');
    expect(pubspec.name, 'example');
    expect(pubspec.description, 'example');
    final metadata = pubspec.unParsedYaml!['metadata']! as Map;
    expect(metadata['base'], {
      'enabled': true,
      'values': ['one', 2, null]
    });
    expect(metadata['copy'], metadata['base']);
    expect(metadata['lists'], [
      ['one', 2, null],
      ['one', 2, null]
    ]);
    // Keep the converter's independent mutable copies of aliased collections.
    expect(identical(metadata['base'], metadata['copy']), isFalse);
  });

  test('compact acyclic expansion is rejected within two seconds', () async {
    // Only 17 anchors and less than 1 KB of source. Without the preflight,
    // this would expand to over 100000 nodes, but is still a bounded fixture.
    final source = StringBuffer('a0: &a0 [leaf]\n');
    for (var i = 1; i <= 16; i++) {
      source.writeln('a$i: &a$i [*a${i - 1}, *a${i - 1}]');
    }
    expect(source.length, lessThan(1024));

    // A timeout on the same isolate cannot interrupt synchronous conversion.
    // Run in a worker and kill it even when a regression exceeds the deadline.
    final reply = ReceivePort();
    final worker = await Isolate.spawn(
        _parseInWorker, (reply.sendPort, source.toString()));
    try {
      expect(await reply.first.timeout(const Duration(seconds: 2)),
          'YAML exceeds 100000 expanded nodes');
    } finally {
      worker.kill(priority: Isolate.immediate);
      reply.close();
    }
  });

  test('depth is bounded for non-alias input', () {
    final source = 'metadata: ${'[' * 64}leaf${']' * 64}';
    expect(() => PubSpec.fromYamlString(source), throwsFormatException);
  });

  test('cached aliases still enforce depth on a deeper path', () {
    final source = 'base: &base [[leaf]]\n'
        'metadata: ${'[' * 62}*base${']' * 62}';
    expect(() => PubSpec.fromYamlString(source), throwsFormatException);
  });

  test('cyclic node graphs are rejected before conversion', () {
    final template = loadYaml('{}') as YamlMap;
    final nodes = <dynamic, YamlNode>{};
    final cyclic = YamlMap.internal(nodes, template.span, template.style);
    nodes[YamlScalar.wrap('self')] = cyclic;
    expect(
        () => parseYaml(cyclic),
        throwsA(isA<FormatException>()
            .having((error) => error.message, 'message', contains('Cyclic'))));
  });
}

void _parseInWorker((SendPort, String) request) {
  try {
    PubSpec.fromYamlString(request.$2);
    request.$1.send('accepted');
  } on FormatException catch (error) {
    request.$1.send(error.message);
  } on Object catch (error) {
    request.$1.send('Unexpected error: $error');
  }
}
