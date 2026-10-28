import 'dart:convert';

// A conservative subset of plain scalars, safe in both key and value positions.
final _plainString = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_ ./:+-]*$');
final _escapedCharacters =
    RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029\ufeff\ufffe\uffff]');
const _primitiveStrings = {
  'null',
  'true',
  'false',
  'yes',
  'no',
  'on',
  'off',
  'y',
  'n',
};

class YamlToString {
  const YamlToString({
    this.indent = ' ',
    this.quotes = "'",
  });

  final String indent;
  final String quotes;
  static const _divider = ': ';

  String toYamlString(Object? node) {
    final stringBuffer = StringBuffer();
    writeYamlString(node, stringBuffer);
    return stringBuffer.toString();
  }

  /// Serializes [node] into a String and writes it to the [sink].
  void writeYamlString(Object? node, StringSink sink) {
    _writeYamlString(node, 0, sink, true);
  }

  void _writeYamlString(
    Object? node,
    int indentCount,
    StringSink stringSink,
    bool isTopLevel,
  ) {
    if (node is Map<Object?, Object?>) {
      _mapToYamlString(node, indentCount, stringSink, isTopLevel);
    } else if (node is Iterable<Object?>) {
      _listToYamlString(node, indentCount, stringSink, isTopLevel);
    } else {
      stringSink.writeln(_scalarToYamlString(node));
    }
  }

  String _escapeString(String line) {
    if (_plainString.stringMatch(line) == line &&
        !line.endsWith(' ') &&
        !line.endsWith(':') &&
        !line.contains(': ') &&
        !_primitiveStrings.contains(line.toLowerCase())) {
      return line;
    }

    if (quotes == "'" && !_escapedCharacters.hasMatch(line)) {
      return "'${line.replaceAll("'", "''")}'";
    }

    // JSON escapes are valid in YAML double-quoted scalars. Also escape YAML
    // line breaks and non-printable characters that JSON leaves literal.
    return jsonEncode(line).replaceAllMapped(_escapedCharacters, (match) {
      final code = match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0');
      return '\\u$code';
    });
  }

  String _scalarToYamlString(Object? node) {
    if (node is String) {
      return _escapeString(node);
    }
    if (node is double) {
      if (node.isNaN) {
        return '!!float .nan';
      }
      if (node.isInfinite) {
        return node.isNegative ? '!!float -.inf' : '!!float .inf';
      }
      return '!!float $node';
    }
    if (node == null || node is bool || node is int) {
      return '$node';
    }
    throw ArgumentError.value(node, 'node', 'Unsupported YAML scalar');
  }

  void _mapToYamlString(
    Map<Object?, Object?> node,
    int indentCount,
    StringSink stringSink,
    bool isTopLevel,
  ) {
    if (node.isEmpty) {
      stringSink.writeln('{}');
      return;
    }
    if (!isTopLevel) {
      stringSink.writeln();
      indentCount += 2;
    }

    final keys = _sortKeys(node);

    for (final key in keys) {
      final value = node[key];
      final encodedKey = _scalarToYamlString(key);
      _writeIndent(indentCount, stringSink);
      // YAML implicit keys are limited to 1024 characters.
      if (encodedKey.length > 1024) {
        stringSink.writeln('? $encodedKey');
        _writeIndent(indentCount, stringSink);
      } else {
        stringSink.write(encodedKey);
      }
      stringSink.write(_divider);
      _writeYamlString(value, indentCount, stringSink, false);
    }
  }

  Iterable<Object?> _sortKeys(Map<Object?, Object?> map) {
    final simple = <Object?>[];
    final maps = <Object?>[];
    final lists = <Object?>[];
    final other = <Object?>[];

    map.forEach((key, value) {
      if (value is String) {
        simple.add(key);
      } else if (value is Map) {
        maps.add(key);
      } else if (value is Iterable) {
        lists.add(key);
      } else {
        other.add(key);
      }
    });

    return [...simple, ...maps, ...lists, ...other];
  }

  void _listToYamlString(
    Iterable<Object?> node,
    int indentCount,
    StringSink stringSink,
    bool isTopLevel,
  ) {
    if (node.isEmpty) {
      stringSink.writeln('[]');
      return;
    }
    if (!isTopLevel) {
      stringSink.writeln();
      indentCount += 2;
    }

    for (final value in node) {
      _writeIndent(indentCount, stringSink);
      stringSink.write('- ');
      _writeYamlString(value, indentCount, stringSink, false);
    }
  }

  void _writeIndent(int indentCount, StringSink stringSink) =>
      stringSink.write(indent * indentCount);
}
