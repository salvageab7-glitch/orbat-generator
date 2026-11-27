/// 单一信源工具：从 app/lib 生成 app/cli_aot/lib，并可只读校验。
///
/// 用法（在 app/ 下）：
///   dart run tool/sync_cli_sources.dart
///   dart run tool/sync_cli_sources.dart --check
///   dart run tool/sync_cli_sources.dart --check --skills
///
/// 退出码：0=一致/同步成功；1=发现漂移；2=参数或路径错误。
library;

import 'dart:io';

const List<String> _managedDirs = <String>[
  'core',
  'ai',
  'render',
  'services',
  'i18n',
];

const List<String> _managedFiles = <String>[
  'pipeline.dart',
  'cli/main.dart',
];

const String _stubRel = 'core/secret_store.dart';
const String _stubSourceRel = 'stubs/secret_store.dart';
const String _skillRel = '.agents/skills/orbat-json-writer';
const String _skillCopyRel = 'app/.agents/skills/orbat-json-writer';

void main(List<String> args) {
  final bool check = args.contains('--check');
  final bool skills = args.contains('--skills');
  final List<String> unknown =
      args.where((String a) => a != '--check' && a != '--skills').toList();
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown argument: ${unknown.join(' ')}');
    stderr.writeln(
        'Usage: dart run tool/sync_cli_sources.dart [--check] [--skills]');
    exit(2);
  }

  final Directory appDir = _resolveAppDir();
  final Directory srcLib = Directory(_join(appDir.path, 'lib'));
  final Directory aotLib = Directory(_join(appDir.path, 'cli_aot/lib'));
  final File stub = File(_join(appDir.path, 'cli_aot/$_stubSourceRel'));

  if (!srcLib.existsSync()) {
    stderr.writeln('Missing source directory: ${srcLib.path}');
    exit(2);
  }
  if (!stub.existsSync()) {
    stderr.writeln('Missing CLI stub: ${stub.path}');
    exit(2);
  }

  final Map<String, List<int>> expected = _expectedFiles(srcLib, stub);

  if (!check) {
    _sync(aotLib, expected);
  }

  final CompareResult cliResult =
      _compare('cli', expected, _actualFiles(aotLib));
  CompareResult? skillResult;
  if (skills) {
    skillResult = _compareSkills(appDir);
  }

  _printResult(cliResult);
  if (skillResult != null) {
    _printResult(skillResult);
  }

  final bool failed = !cliResult.ok || (skillResult != null && !skillResult.ok);
  if (failed) {
    stderr.writeln('FAILED');
    exit(1);
  }
  stdout.writeln('OK');
}

Directory _resolveAppDir() {
  final Uri script = Platform.script;
  if (script.scheme == 'file') {
    final File file = File.fromUri(script);
    if (file.existsSync() && file.parent.uri.pathSegments.length >= 2) {
      final Directory parent = file.parent;
      if (parent.uri.pathSegments.where((String s) => s.isNotEmpty).last ==
          'tool') {
        return parent.parent;
      }
    }
  }
  return Directory.current;
}

Map<String, List<int>> _expectedFiles(Directory srcLib, File stub) {
  final Map<String, List<int>> result = <String, List<int>>{};

  for (final String dir in _managedDirs) {
    final Directory source = Directory(_join(srcLib.path, dir));
    if (!source.existsSync()) continue;
    for (final File file in _filesUnder(source)) {
      result[_relative(file, srcLib)] = file.readAsBytesSync();
    }
  }

  for (final String rel in _managedFiles) {
    final File file = File(_join(srcLib.path, rel));
    if (file.existsSync()) {
      result[rel] = file.readAsBytesSync();
    }
  }

  // CLI 是纯 Dart AOT，不能用 Flutter/Android Keystore 版。
  result[_stubRel] = stub.readAsBytesSync();
  return result;
}

Map<String, List<int>> _actualFiles(Directory aotLib) {
  final Map<String, List<int>> result = <String, List<int>>{};

  for (final String dir in _managedDirs) {
    final Directory source = Directory(_join(aotLib.path, dir));
    if (!source.existsSync()) continue;
    for (final File file in _filesUnder(source)) {
      result[_relative(file, aotLib)] = file.readAsBytesSync();
    }
  }

  for (final String rel in _managedFiles) {
    final File file = File(_join(aotLib.path, rel));
    if (file.existsSync()) {
      result[rel] = file.readAsBytesSync();
    }
  }

  return result;
}

void _sync(Directory aotLib, Map<String, List<int>> expected) {
  // managed 目录整体重建；env_probe.dart、stubs/、.dart_tool/、orbat-logs/ 不动。
  for (final String dir in _managedDirs) {
    final Directory target = Directory(_join(aotLib.path, dir));
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
  }
  final File pipeline = File(_join(aotLib.path, 'pipeline.dart'));
  if (pipeline.existsSync()) pipeline.deleteSync();
  final Directory cli = Directory(_join(aotLib.path, 'cli'));
  if (cli.existsSync()) cli.deleteSync(recursive: true);

  for (final MapEntry<String, List<int>> entry in expected.entries) {
    final File target = File(_join(aotLib.path, entry.key));
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(entry.value);
  }

  stdout.writeln('Synced ${expected.length} files to ${aotLib.path}');
}

CompareResult _compare(
  String label,
  Map<String, List<int>> expected,
  Map<String, List<int>> actual,
) {
  final List<String> missing = <String>[];
  final List<String> extra = <String>[];
  final List<String> different = <String>[];
  final List<String> flutter = <String>[];

  for (final String rel in expected.keys) {
    if (!actual.containsKey(rel)) {
      missing.add(rel);
    } else if (!_bytesEqual(expected[rel]!, actual[rel]!)) {
      different.add(rel);
    }
  }
  for (final String rel in actual.keys) {
    if (!expected.containsKey(rel)) {
      extra.add(rel);
    }
  }
  for (final MapEntry<String, List<int>> entry in actual.entries) {
    if (_containsFlutterImport(entry.value)) {
      flutter.add(entry.key);
    }
  }

  return CompareResult(
    label: label,
    missing: missing..sort(),
    extra: extra..sort(),
    different: different..sort(),
    flutter: flutter..sort(),
  );
}

CompareResult _compareSkills(Directory appDir) {
  final Directory root = Directory(_join(appDir.path, '../$_skillRel'));
  final Directory copy = Directory(_join(appDir.path, '../$_skillCopyRel'));

  if (!root.existsSync() || !copy.existsSync()) {
    return CompareResult(
      label: 'skills',
      missing: <String>[if (!root.existsSync()) 'root skill directory missing'],
      extra: <String>[if (!copy.existsSync()) 'app skill copy missing'],
      different: <String>[],
      flutter: <String>[],
    );
  }

  final Map<String, List<int>> expected = <String, List<int>>{
    for (final File file in _filesUnder(root))
      _relative(file, root): file.readAsBytesSync(),
  };
  final Map<String, List<int>> actual = <String, List<int>>{
    for (final File file in _filesUnder(copy))
      _relative(file, copy): file.readAsBytesSync(),
  };

  return _compare('skills', expected, actual);
}

bool _containsFlutterImport(List<int> bytes) {
  final String text = String.fromCharCodes(bytes);
  return text.contains('package:flutter');
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<File> _filesUnder(Directory dir) {
  return dir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList();
}

String _relative(File file, Directory base) {
  final String basePath = base.absolute.path.endsWith(Platform.pathSeparator)
      ? base.absolute.path
      : '${base.absolute.path}${Platform.pathSeparator}';
  return file.absolute.path.substring(basePath.length).replaceAll('\\', '/');
}

String _join(String a, String b) {
  final String left =
      a.endsWith(Platform.pathSeparator) ? a.substring(0, a.length - 1) : a;
  final String right = b.replaceAll('/', Platform.pathSeparator);
  return '$left${Platform.pathSeparator}$right';
}

void _printResult(CompareResult result) {
  stdout.writeln('[${result.label}] checked');
  if (result.missing.isNotEmpty) {
    stdout.writeln('  missing (${result.missing.length}):');
    for (final String rel in result.missing) {
      stdout.writeln('    - $rel');
    }
  }
  if (result.extra.isNotEmpty) {
    stdout.writeln('  extra (${result.extra.length}):');
    for (final String rel in result.extra) {
      stdout.writeln('    + $rel');
    }
  }
  if (result.different.isNotEmpty) {
    stdout.writeln('  different (${result.different.length}):');
    for (final String rel in result.different) {
      stdout.writeln('    ~ $rel');
    }
  }
  if (result.flutter.isNotEmpty) {
    stdout.writeln('  flutter-import (${result.flutter.length}):');
    for (final String rel in result.flutter) {
      stdout.writeln('    ! $rel');
    }
  }
}

class CompareResult {
  CompareResult({
    required this.label,
    required this.missing,
    required this.extra,
    required this.different,
    required this.flutter,
  });

  final String label;
  final List<String> missing;
  final List<String> extra;
  final List<String> different;
  final List<String> flutter;

  bool get ok =>
      missing.isEmpty && extra.isEmpty && different.isEmpty && flutter.isEmpty;
}
