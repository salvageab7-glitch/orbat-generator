/// 内置教程窗口（纯文字，随界面语言切换）
///
/// 为什么要内置一份纯文字版：用户手上不一定有那份 doc 教程，
/// 尤其在另一台机器上遇到"出图不动了""符号是方块"时，能就地查一步怎么做。
/// 内容与 CLI `tutorial` 命令共用同一份 `tutorial_text.dart`，不会两处不一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/l10n.dart';
import '../i18n/tutorial_text.dart';

/// 打开教程窗口。任意位置调用，关闭后无副作用。
Future<void> showTutorialDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => const _TutorialDialog(),
  );
}

class _TutorialDialog extends StatefulWidget {
  const _TutorialDialog();

  @override
  State<_TutorialDialog> createState() => _TutorialDialogState();
}

class _TutorialDialogState extends State<_TutorialDialog> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: tutorialText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('教程全文已复制到剪贴板')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 窗口大小跟随屏幕，别在小屏上被裁掉；最大 820×660
    final media = MediaQuery.of(context).size;
    final width = (media.width * 0.78).clamp(420.0, 820.0);
    final height = (media.height * 0.78).clamp(360.0, 660.0);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.menu_book_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('使用教程'))),
          Text(
            kTutorialRevision,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('纯文字版，随界面语言切换；完整图文教程见发布页的 doc 文档。'),
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                    child: SelectableText(
                      tutorialText(),
                      style: const TextStyle(fontSize: 12.5, height: 1.65),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _copyAll,
          icon: const Icon(Icons.copy_all_outlined, size: 16),
          label: Text(tr('复制全文')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('关闭')),
        ),
      ],
    );
  }
}
