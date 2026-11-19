/// 界面语言切换通知（Flutter 层）
///
/// 翻译状态本身是纯 Dart（`l10n.dart`），这里只提供"变了吗"的信号，
/// 让 MaterialApp 重建整棵树。改语言时用 [applyLanguage]，别直接调 L10n.apply，
/// 否则界面不会刷新。
library;

import 'package:flutter/foundation.dart';

import '../i18n/l10n.dart';

/// 每次切换语言 +1，UI 监听它重建
final ValueNotifier<int> l10nRevision = ValueNotifier<int>(0);

/// 改语言：更新翻译状态并触发重建
void applyLanguage(String code) {
  L10n.apply(code);
  l10nRevision.value++;
}
