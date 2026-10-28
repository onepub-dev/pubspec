// yaml has no public streaming event API. Keep this dependency isolated here;
// the Parser/event members used below were inspected in yaml 3.1.0–3.1.4.
// ignore: implementation_imports
import 'package:yaml/src/event.dart';
// ignore: implementation_imports
import 'package:yaml/src/parser.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_extension/yaml_extension.dart';

import 'dependency/dependency.dart';
import 'type.dart';

YamlParser parseYaml(YamlMap j, {bool consumeMap = false}) =>
    YamlParser(j, consumeMap: consumeMap);

// Count the expanded tree before yaml_extension allocates it. These limits
// leave ample room for pubspec metadata while bounding conversion work and
// recursion, including for small documents with heavily shared aliases.
const _maxExpandedNodes = 100000;
const _maxYamlDepth = 64;
const _maxYamlEvents = 200004;

/// Rejects collection keys before the loader can recursively hash them.
///
/// This bounds events and source nesting, not source bytes or scanner runtime.
/// Expanded alias size and depth are checked separately before conversion.
void preflightYaml(String source) {
  final parser = Parser(source);
  final stack = <_CollectionFrame>[];
  final collectionAnchors = <String, bool>{};
  var eventCount = 0;
  while (!parser.isDone) {
    if (++eventCount > _maxYamlEvents) {
      throw const FormatException('YAML exceeds 200004 parser events');
    }
    final event = parser.parse();
    if (event.type == EventType.documentStart) {
      collectionAnchors.clear();
    }
    if (event.type == EventType.mappingEnd ||
        event.type == EventType.sequenceEnd) {
      stack.removeLast();
      continue;
    }
    final isCollection =
        event is MappingStartEvent || event is SequenceStartEvent;
    if (!isCollection && event is! ScalarEvent && event is! AliasEvent) {
      continue;
    }
    if (stack.length + 1 > _maxYamlDepth) {
      throw const FormatException('YAML exceeds maximum depth of 64');
    }

    String? anchor;
    if (event is ScalarEvent) {
      anchor = event.anchor;
    }
    if (event is MappingStartEvent) {
      anchor = event.anchor;
    }
    if (event is SequenceStartEvent) {
      anchor = event.anchor;
    }
    // YAML permits rebinding anchors. Register at collection start so a
    // self-reference used as a key is rejected too.
    if (anchor != null) {
      collectionAnchors[anchor] = isCollection;
    }
    if (event is AliasEvent && !collectionAnchors.containsKey(event.name)) {
      throw const FormatException('Undefined YAML alias');
    }
    if (stack.isNotEmpty && stack.last.isMapping) {
      final parent = stack.last;
      if (parent.expectsKey &&
          (isCollection ||
              (event is AliasEvent && collectionAnchors[event.name]!))) {
        throw const FormatException('YAML mapping keys must be scalars');
      }
      parent.expectsKey = !parent.expectsKey;
    }
    if (isCollection) {
      stack.add(_CollectionFrame(isMapping: event is MappingStartEvent));
    }
  }
}

class _CollectionFrame {
  _CollectionFrame({required this.isMapping});
  final bool isMapping;
  bool expectsKey = true;
}

Map<String, dynamic> _boundedToMap(YamlMap yamlMap) {
  final sizes = Map<YamlNode, ({int size, int height})>.identity();
  final active = Set<YamlNode>.identity();

  ({int size, int height}) measure(YamlNode node, int depth) {
    if (depth > _maxYamlDepth) {
      throw const FormatException('YAML exceeds maximum depth of 64');
    }
    if (active.contains(node)) {
      throw const FormatException('Cyclic YAML aliases are not supported');
    }
    final cached = sizes[node];
    if (cached != null) {
      // A shared subtree can be encountered later on a deeper path.
      if (depth + cached.height - 1 > _maxYamlDepth) {
        throw const FormatException('YAML exceeds maximum depth of 64');
      }
      return cached;
    }

    active.add(node);
    var size = 1;
    var height = 1;
    void addChild(YamlNode child) {
      final measured = measure(child, depth + 1);
      // Subtract before adding so the accounting never grows past the limit.
      if (measured.size > _maxExpandedNodes - size) {
        throw const FormatException('YAML exceeds 100000 expanded nodes');
      }
      size += measured.size;
      if (measured.height + 1 > height) {
        height = measured.height + 1;
      }
    }

    if (node is YamlMap) {
      final normalizedKeys = <String>{};
      for (final entry in node.nodes.entries) {
        if (entry.key is! YamlScalar) {
          throw const FormatException('YAML mapping keys must be scalars');
        }
        final key = (entry.key as YamlScalar).value.toString();
        if (!normalizedKeys.add(key)) {
          throw const FormatException(
              'YAML mapping keys collide after string conversion');
        }
        addChild(entry.key as YamlNode);
        addChild(entry.value);
      }
    } else if (node is YamlList) {
      for (final child in node.nodes) {
        addChild(child);
      }
    }
    active.remove(node);
    final result = (size: size, height: height);
    sizes[node] = result;
    return result;
  }

  measure(yamlMap, 1);
  return yamlMap.toMap();
}

class YamlParser {
  YamlParser(YamlMap yamlMap, {required bool consumeMap})
      : _yamlMap = _boundedToMap(yamlMap),
        _consumeMap = consumeMap;
  final Map<String, dynamic> _yamlMap;
  final bool _consumeMap;

  List<T> list<T>(String fieldName, [Converter<T, List<T>>? create]) {
    final l = _getField(fieldName) as List?;
    return l != null
        ? l.map((v) => converter(create)).toList(growable: false) as List<T>
        : <T>[];
  }

  T? single<T, V>(String fieldName, [Create<T, V>? create]) {
    final j = _getField(fieldName) as V?;
    return j != null ? converter<T, V>(create)(j) : null;
  }

  Map<String, DependencyReference> getReferences(String fieldName) {
    final dependencies = _getField(fieldName) as Json?;

    if (dependencies == null) {
      return {};
    }

    final map = <String, DependencyReference>{};
    for (final key in dependencies.keys) {
      final reference = DependencyReference.fromJson(dependencies[key]);
      map.putIfAbsent(key, () => reference);
    }
    return map;
  }

  Map<K, DependencyReference> mapValues<K>(String fieldName,
      [Converter<K, DependencyReference>? convertValue,
      Converter<K, DependencyReference>? convertKey]) {
    final m = _getField(fieldName) as Map<K, DependencyReference>?;

    if (m == null) {
      return {};
    }

    final _convertKey = converter(convertKey);
    final _convertValue = converter(convertValue);

    final result = <K, DependencyReference>{};
    m.forEach((k, v) {
      result[_convertKey(k as DependencyReference)] =
          _convertValue(v) as DependencyReference;
    });

    return result;
  }

  Map<K, V> mapEntries<K, V, T>(
      String fieldName, V Function(K k, T v) convert) {
    final m = _getField(fieldName) as Map<K, V>?;

    if (m == null) {
      return {};
    }

    final result = <K, V>{};
    m.forEach((k, v) {
      result[k] = convert(k, v as T);
    });

    return result;
  }

  T? _getField<T>(String fieldName) =>
      (_consumeMap ? _yamlMap.remove(fieldName) : _yamlMap[fieldName]) as T?;

  Map<String, dynamic> get unconsumed {
    if (!_consumeMap) {
      throw StateError('unconsumed called on non consuming parser');
    }

    return _yamlMap;
  }

  Map<String, T> getPairs<T>(
      String fieldName, T Function(String name, String? script) convert) {
    final result = <String, T>{};

    final map = _getField(fieldName) as Json?;

    if (map == null) {
      return {};
    }
    for (final key in map.keys) {
      result.putIfAbsent(key, () => convert(key, map[key] as String?));
    }
    return result;
  }
}
