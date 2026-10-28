import 'dart:io';
import 'dart:isolate';

import 'package:dcli_core/dcli_core.dart' as core;
import 'package:pubspec2/pubspec2.dart';
import 'package:pubspec2/src/yaml_util.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('already loaded maps also reject normalization collisions', () {
    final loaded = loadYaml('custom: {"1": keep, 1: replace}') as YamlMap;
    expect(() => PubSpec.fromYaml(loaded), throwsFormatException);
  });

  for (final keys in [
    '"1": keep\n  1: replace',
    '"true": keep\n  true: replace',
    '"null": keep\n  null: replace'
  ]) {
    test('rejects normalized key collision: $keys', () {
      expect(
          () => PubSpec.fromYamlString('custom:\n  $keys\n'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('collide after string conversion'))));
    });
  }

  test('noncolliding scalar keys retain established string conversion', () {
    final spec =
        PubSpec.fromYamlString('custom: {1: one, true: yes, null: nil}');
    expect(spec.unParsedYaml!['custom'],
        {'1': 'one', 'true': 'yes', 'null': 'nil'});
  });

  for (final source in [
    '? [one, two]\n: ignored',
    '? {one: two}\n: ignored',
    'base: &base [leaf]\n? *base\n: ignored',
    'base: &base {leaf: value}\n? *base\n: ignored',
    'base: &base scalar\nrebound: &base []\n? *base\n: ignored',
    'base: &base {? *base : ignored}',
    'custom: [{? [leaf] : ignored}]',
  ]) {
    test('preflight rejects collection key: $source', () {
      expect(
          () => preflightYaml(source),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              'YAML mapping keys must be scalars')));
      expect(() => PubSpec.fromYamlString(source), throwsFormatException);
    });
  }

  test('scalar alias keys and collection-to-scalar rebinding are allowed', () {
    final spec = PubSpec.fromYamlString('''
base: &key []
rebound: &key scalar
custom: {*key : retained}
''');
    expect(spec.unParsedYaml!['custom'], {'scalar': 'retained'});
  });

  test('preflight resets anchors between documents', () {
    expect(() => preflightYaml('base: &key scalar\n---\n*key'),
        throwsFormatException);
    preflightYaml('base: &key []\n---\nbase: &key scalar\ncustom: {*key : ok}');
  });

  test('loadFile applies collection-key preflight', () async {
    await core.withTempDir((directory) async {
      final path = '$directory/pubspec.yaml';
      await File(path).writeAsString('base: &base [leaf]\n? *base\n: ignored');
      await expectLater(PubSpec.loadFile(path), throwsFormatException);
    });
  });

  test('source nesting accepts depth 64 and rejects depth 65', () {
    PubSpec.fromYamlString('custom: ${'[' * 62}leaf${']' * 62}');
    expect(() => preflightYaml('custom: ${'[' * 63}leaf${']' * 63}'),
        throwsFormatException);
  });

  test('preflight event budget has an exact finite boundary', () {
    // Nine framing events: stream/document/map/sequence starts and ends,
    // plus the scalar mapping key. No alias expansion or loader allocation.
    final items = List.filled(199995, 'x').join(',');
    preflightYaml('custom: [$items]');
    expect(
        () => preflightYaml('custom: [$items,x]'),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', 'YAML exceeds 200004 parser events')));
  });

  test('collection alias key with sharing is rejected within two seconds',
      () async {
    final source = StringBuffer('a0: &a0 [leaf]\n');
    for (var i = 1; i <= 12; i++) {
      source.writeln('a$i: &a$i [*a${i - 1}, *a${i - 1}]');
    }
    source.writeln('? *a12\n: ignored');
    final reply = ReceivePort();
    final worker = await Isolate.spawn(
        _parseInWorker, (reply.sendPort, source.toString()));
    try {
      expect(await reply.first.timeout(const Duration(seconds: 2)),
          'YAML mapping keys must be scalars');
    } finally {
      worker.kill(priority: Isolate.immediate);
      reply.close();
    }
  });

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
