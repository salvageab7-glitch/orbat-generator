/// 应用路径约定 —— 输出归档目录
///
/// 统一规则：所有产物默认落到「软件（exe）所在目录\输出文件存档\」。
///   ① 不污染用户桌面（0.3.2 之前 GUI 默认写桌面根）
///   ② 便携版/安装版行为一致：程序在哪，产物就在它旁边
///   ③ 本机沙盒 ACL 只允许 exe 写自己目录树，这条规则天然安全
///
/// CLI 与 GUI 共用本文件，保证两边宣告的目录是同一个。
library;

import 'dart:io';

/// 归档目录名（中文，用户一眼能认出）
const String kArchiveDirName = '输出文件存档';

/// 可执行文件所在目录（发布版 = 软件安装目录）。
///
/// 取不到时退回当前工作目录，保证任何情况下都有可用值。
String get appDirPath {
  try {
    final exe = File(Platform.resolvedExecutable);
    final dir = exe.parent.path;
    if (dir.isNotEmpty) return dir;
  } catch (_) {
    // 某些沙盒环境禁用 resolvedExecutable
  }
  return Directory.current.path;
}

/// 默认输出归档目录的绝对路径（不保证已创建）
String get defaultArchiveDir => '$appDirPath${Platform.pathSeparator}$kArchiveDirName';

/// 解析结果的进程内缓存：outputDir 在 build() 里被反复读取，
/// 每次都做写入探测会拖慢界面，所以只解析一次。
String? _cachedArchiveDir;

/// 确保归档目录存在并返回其路径。
///
/// 依次尝试：exe 同级「输出文件存档」→「我的文档\输出文件存档」→ 系统临时目录。
/// 为什么要有第二级：安装版装进 `C:\Program Files` 时普通用户对该目录无写权限，
/// 此时退回文档目录（用户可写、也好找），而不是把产物丢进看不见的 Temp。
/// 任何一级失败都不抛异常，绝不让出图流程因此中断。
String ensureArchiveDir() {
  final cached = _cachedArchiveDir;
  if (cached != null && Directory(cached).existsSync()) return cached;

  final candidates = <String>[defaultArchiveDir];
  final docDir = _documentsDir();
  if (docDir != null) {
    candidates.add('$docDir${Platform.pathSeparator}$kArchiveDirName');
  }

  for (final target in candidates) {
    try {
      final d = Directory(target);
      if (!d.existsSync()) d.createSync(recursive: true);
      // createSync 在部分只读场景不抛错，补一次真实写入探测
      if (_isWritable(d.path)) {
        _cachedArchiveDir = d.path;
        return d.path;
      }
    } catch (_) {
      // 换下一个候选
    }
  }

  try {
    final fallback = Directory('${Directory.systemTemp.path}/$kArchiveDirName');
    if (!fallback.existsSync()) fallback.createSync(recursive: true);
    _cachedArchiveDir = fallback.path;
    return fallback.path;
  } catch (_) {
    return Directory.systemTemp.path;
  }
}

/// 我的文档目录（优先 USERPROFILE\Documents，兼容 OneDrive 重定向缺失的情况）
String? _documentsDir() {
  if (!Platform.isWindows) return Platform.environment['HOME'];
  final up = Platform.environment['USERPROFILE'];
  if (up == null || up.isEmpty) return null;
  for (final name in ['Documents', '文档']) {
    final p = '$up\\$name';
    if (Directory(p).existsSync()) return p;
  }
  return up;
}

/// 真实写入探测：只读目录/受控目录下 create 可能不抛错，写一次最可靠
bool _isWritable(String path) {
  try {
    final probe = File('$path${Platform.pathSeparator}.orbat_write_probe');
    probe.writeAsStringSync('ok');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

/// 确保任意用户指定目录存在（存在即返回，不存在则尝试创建）
bool ensureDirExists(String path) {
  try {
    final d = Directory(path);
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.existsSync();
  } catch (_) {
    return false;
  }
}
