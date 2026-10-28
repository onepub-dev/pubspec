import 'package:pubspec2/pubspec2.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const writer = YamlToString();

  test('unknown map key cannot inject publish_to', () {
    const source = 'name: demo\n"marker: old\\npublish_to": none\n';
    final input = loadYaml(source) as YamlMap;
    final pubspec = PubSpec.fromYamlString(source);
    expect(input.containsKey('publish_to'), isFalse);
    expect(pubspec.publishTo, isNull);

    final output = writer.toYamlString(pubspec.toJson());
    final parsed = loadYaml(output) as YamlMap;
    expect(parsed, equals(input));
    expect(parsed.containsKey('publish_to'), isFalse);
    expect(parsed['marker: old\npublish_to'], 'none');
  });

  const strings = <String>[
    '',
    ' ',
    ' leading',
    'trailing ',
    "it's a package",
    "'quoted'",
    "owner's: package",
    'a "quoted" value',
    r'C:\new\test',
    r'literal\ntext',
    'line\nbreak',
    'trailing\n',
    'line\rbreak',
    'trailing\r',
    'line\r\nbreak',
    'tab\there',
    '\x00\x01\x1f\x7f\x85\x9f',
    'line\u2028break\u2029end',
    '\ufefftext\ufffe\uffff',
    'unicode café 😀',
    'null',
    'Null',
    'NULL',
    '~',
    'true',
    'False',
    'TRUE',
    'yes',
    'NO',
    'on',
    'off',
    'y',
    'n',
    '0',
    '01',
    '123',
    '-42',
    '+42',
    '0xFF',
    '0o77',
    '1.0',
    '1e3',
    '.inf',
    '-.Inf',
    '.NaN',
    '2026-10-29',
    '12:34:56',
    '[]',
    '{}',
    '[one, two]',
    '{publish_to: none}',
    '# comment',
    'value # comment',
    '&anchor',
    '*alias',
    '!!str value',
    '<<',
    '- item',
    '? key',
    ': value',
    'key: value',
    'key:',
    '---',
    '...',
    '|',
    '>',
    '%YAML 1.2',
    "x'\npublish_to: none\n#",
    'x\rpublish_to: none',
  ];

  for (final quotes in ["'", '"']) {
    group('strings with $quotes quoting', () {
      final encoder = YamlToString(quotes: quotes);
      for (var i = 0; i < strings.length; i++) {
        test('scalar and map key $i preserve content and type', () {
          final value = strings[i];
          final scalar = loadYaml(encoder.toYamlString(value));
          expect(scalar, isA<String>());
          expect(scalar, value);

          final map = loadYaml(encoder.toYamlString({value: value})) as YamlMap;
          expect(map, equals({value: value}));
          expect(map.keys.single, isA<String>());
          expect(map.values.single, isA<String>());
        });
      }

      test('all strings in a list', () {
        expect(loadYaml(encoder.toYamlString(strings)), equals(strings));
      });
    });
  }

  test('single quotes double apostrophes and double quotes escape CR', () {
    expect(writer.toYamlString("owner's: package"), "'owner''s: package'\n");
    expect(writer.toYamlString('a\rb'), '"a\\rb"\n');
  });

  test('mixed collections preserve structure, nulls and scalar types', () {
    final input = <String, Object?>{
      'nested': <Object?>[
        {
          'marker: old\npublish_to': 'none',
          'values': <Object?>[
            'true',
            true,
            '1',
            1,
            '1.0',
            1.0,
            '',
            null,
            <String, Object?>{},
            <Object?>[],
          ],
        },
        <Object?>[
          ['a\rb', "it's: safe"],
          {'key': 'value'},
        ],
      ],
      'empty_map': <String, Object?>{},
      'empty_list': <Object?>[],
      'null_value': null,
    };
    final parsed = loadYaml(writer.toYamlString(input)) as YamlMap;
    expect(parsed, equals(input));
    final nested = parsed['nested'] as YamlList;
    final values = (nested.first as YamlMap)['values'] as YamlList;
    expect(values[0], isA<String>());
    expect(values[1], isA<bool>());
    expect(values[2], isA<String>());
    expect(values[3], isA<int>());
    expect(values[4], isA<String>());
    expect(values[5], isA<double>());
    expect(values[6], '');
    expect(values[7], isNull);
  });

  test('unknown pubspec fields preserve nested lists and maps', () {
    const source = 'name: demo\n'
        'custom:\n'
        '  entries:\n'
        '    - "marker: old\\npublish_to": none\n'
        '      values: ["false", false, "", null, {}, []]\n'
        '    - ["owner\'s", "a\\rb", "1", 1]\n';
    final pubspec = PubSpec.fromYamlString(source);
    final parsed = loadYaml(writer.toYamlString(pubspec.toJson()));
    expect(parsed, equals(loadYaml(source)));
  });

  test('empty root collections and null retain their types', () {
    expect(loadYaml(writer.toYamlString(<String, Object?>{})), isA<YamlMap>());
    expect(loadYaml(writer.toYamlString(<Object?>[])), isA<YamlList>());
    expect(loadYaml(writer.toYamlString(null)), isNull);
  });

  test('long keys use explicit key syntax', () {
    final key = 'a' * 1025;
    final input = {
      'nested': {key: 'value'},
    };
    expect(loadYaml(writer.toYamlString(input)), equals(input));
  });

  test('numeric and boolean map keys preserve their types', () {
    final input = <Object?, Object?>{1: 'one', true: 'yes', null: 'nil'};
    expect(loadYaml(writer.toYamlString(input)), equals(input));
  });

  test('non-finite doubles have valid YAML float representations', () {
    final parsed = loadYaml(writer.toYamlString(
      [double.nan, double.infinity, double.negativeInfinity],
    )) as YamlList;
    expect((parsed[0] as double).isNaN, isTrue);
    expect(parsed[1], double.infinity);
    expect(parsed[2], double.negativeInfinity);
  });

  test('normal pubspec keeps readable keys and values', () {
    const source = 'name: demo\n'
        'version: 1.2.3\n'
        'description: A simple package\n'
        'homepage: https://example.com/demo\n'
        'environment:\n'
        '  sdk: ">=3.0.0 <4.0.0"\n'
        'dependencies:\n'
        '  yaml: ^3.1.0\n'
        '  local:\n'
        '    path: ../local\n'
        'custom:\n'
        '  enabled: true\n';
    final pubspec = PubSpec.fromYamlString(source);
    final output = writer.toYamlString(pubspec.toJson());
    expect(loadYaml(output), equals(loadYaml(source)));
    expect(output, contains('name: demo\n'));
    expect(output, contains('description: A simple package\n'));
    expect(output, contains('homepage: https://example.com/demo\n'));
    expect(output, contains('dependencies: \n  yaml:'));
  });
}
