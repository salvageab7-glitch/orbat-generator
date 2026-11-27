/// ORBAT JSON Schema 自检：不依赖外部包，验证结构契约的合法/非法样例。
///
/// 只实现本 Schema 用到的关键字：$ref/type/required/properties/
/// additionalProperties/items/pattern/enum/minLength/maxLength。
/// 业务红牌/warn 由 OrbatValidator 负责，不在这里重复。
library;

import 'dart:convert';
import 'dart:io';

import 'package:orbat_core/core/orbat_schema.dart';

class _SchemaValidator {
  final Map<String, dynamic> root;

  _SchemaValidator(this.root);

  List<String> validate(dynamic value) {
    final errors = <String>[];
    _check(root, value, r'$', errors, 0);
    return errors;
  }

  Map<String, dynamic> _resolve(Map<String, dynamic> schema) {
    final ref = schema[r'$ref'];
    if (ref is! String || !ref.startsWith('#/')) return schema;
    dynamic cur = root;
    for (final part in ref.substring(2).split('/')) {
      cur = (cur as Map<String, dynamic>)[part];
    }
    return cur as Map<String, dynamic>;
  }

  void _check(
    Map<String, dynamic> rawSchema,
    dynamic value,
    String path,
    List<String> errors,
    int depth,
  ) {
    if (depth > 200) {
      errors.add('$path: 嵌套过深');
      return;
    }
    final schema = _resolve(rawSchema);
    final type = schema['type'];

    bool typeOk = true;
    if (type == 'object') typeOk = value is Map;
    if (type == 'array') typeOk = value is List;
    if (type == 'string') typeOk = value is String;
    if (type == 'boolean') typeOk = value is bool;
    if (type == 'number') typeOk = value is num;
    if (type == 'integer') typeOk = value is int;
    if (!typeOk) {
      errors.add('$path: 类型应为 $type');
      return;
    }

    if (value is Map) {
      final required =
          (schema['required'] as List?)?.cast<String>() ?? const [];
      for (final key in required) {
        if (!value.containsKey(key)) errors.add('$path: 缺少 $key');
      }
      final props = (schema['properties'] as Map?)?.cast<String, dynamic>();
      if (props != null) {
        for (final entry in value.entries) {
          final key = entry.key.toString();
          final sub = props[key];
          if (sub is Map<String, dynamic>) {
            _check(sub, entry.value, '$path.$key', errors, depth + 1);
          } else if (schema['additionalProperties'] == false) {
            errors.add('$path: 不允许字段 $key');
          }
        }
      }
    } else if (value is List) {
      final items = schema['items'];
      if (items is Map<String, dynamic>) {
        for (var i = 0; i < value.length; i++) {
          _check(items, value[i], '$path[$i]', errors, depth + 1);
        }
      }
    } else if (value is String) {
      final pattern = schema['pattern'];
      if (pattern is String && !RegExp(pattern).hasMatch(value)) {
        errors.add('$path: 不匹配 $pattern');
      }
      final minLength = schema['minLength'];
      if (minLength is int && value.length < minLength) {
        errors.add('$path: 长度 < $minLength');
      }
      final maxLength = schema['maxLength'];
      if (maxLength is int && value.length > maxLength) {
        errors.add('$path: 长度 > $maxLength');
      }
      final enums = schema['enum'];
      if (enums is List && !enums.contains(value)) {
        errors.add('$path: 不在枚举 $enums');
      }
    }
  }
}

void main() {
  final schema = jsonDecode(kOrbatSchemaJson) as Map<String, dynamic>;
  final validator = _SchemaValidator(schema);
  var pass = 0;
  var fail = 0;

  void check(String name, bool cond) {
    if (cond) {
      pass++;
      print('  PASS  $name');
    } else {
      fail++;
      print('  FAIL  $name');
    }
  }

  final sample = jsonDecode(
    File('assets/test/smoke_orbat.json').readAsStringSync(),
  );
  check('内置 3 节点样例通过 Schema', validator.validate(sample).isEmpty);

  Map<String, dynamic> clone() =>
      jsonDecode(jsonEncode(sample)) as Map<String, dynamic>;

  final missingSidc = clone();
  (missingSidc['options'] as Map).remove('sidc');
  check('缺少 sidc 被拒绝', validator.validate(missingSidc).isNotEmpty);

  final extraKey = clone();
  (extraKey['options'] as Map)['range'] = '10km';
  check('options 多第 8 键被拒绝', validator.validate(extraKey).isNotEmpty);

  final badSidc = clone();
  (badSidc['options'] as Map)['sidc'] = '123';
  check('sidc 非 30 位被拒绝', validator.validate(badSidc).isNotEmpty);

  final childLevels = clone();
  final firstChild =
      (childLevels['subOrganizations'] as List).first as Map<String, dynamic>;
  firstChild['commandLevels'] = '3';
  check('子节点带 commandLevels 被拒绝', validator.validate(childLevels).isNotEmpty);

  final badChildren = clone();
  badChildren['subOrganizations'] = 'not-an-array';
  check('subOrganizations 非数组被拒绝', validator.validate(badChildren).isNotEmpty);

  final badRoot = clone();
  badRoot['commandLevels'] = 3;
  check('commandLevels 非字符串被拒绝', validator.validate(badRoot).isNotEmpty);

  print('\n=== 结果: PASS $pass / FAIL $fail ===');
  if (fail > 0) exitCode = 1;
}
