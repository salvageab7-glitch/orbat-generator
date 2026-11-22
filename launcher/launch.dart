// 启动器：找到同目录下最新的「编制生成器v*.exe」并运行
// 这样版本号变化时不需要改启动入口
import 'dart:io';

void main(List<String> args) {
  final self = Platform.resolvedExecutable;
  final dir = File(self).parent;

  final candidates = dir
      .listSync()
      .whereType<File>()
      .where((f) {
        final n = f.path.split(Platform.pathSeparator).last;
        return n.endsWith('.exe') &&
            n.contains('编制生成器') &&
            !n.contains('启动');
      })
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));

  if (candidates.isEmpty) {
    stderr.writeln('未找到 编制生成器*.exe，请确认文件是否完整。');
    exit(1);
  }

  try {
    Process.start(
      candidates.first.path,
      args,
      mode: ProcessStartMode.detached,
      workingDirectory: dir.path,
    );
    exit(0);
  } catch (e) {
    stderr.writeln('启动失败: $e');
    exit(1);
  }
}
