/// 语言探测与内置教程的回归测试（纯 Dart，不依赖 Flutter）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbat_core/i18n/l10n.dart';
import 'package:orbat_core/i18n/tutorial_text.dart';

void main() {
  group('系统语言 → 界面语言', () {
    test('中文系统（各区域）→ 中文', () {
      expect(L10n.langForLocale('zh-CN'), AppLang.zh);
      expect(L10n.langForLocale('zh-TW'), AppLang.zh);
      expect(L10n.langForLocale('zh'), AppLang.zh);
      expect(L10n.langForLocale('ZH-Hans'), AppLang.zh);
    });

    test('英文系统 → 英文', () {
      expect(L10n.langForLocale('en-US'), AppLang.en);
      expect(L10n.langForLocale('en-GB'), AppLang.en);
      expect(L10n.langForLocale('en'), AppLang.en);
    });

    test('其他语言一律英文（按产品要求）', () {
      expect(L10n.langForLocale('ja-JP'), AppLang.en);
      expect(L10n.langForLocale('ru-RU'), AppLang.en);
      expect(L10n.langForLocale('de-DE'), AppLang.en);
      expect(L10n.langForLocale('ko-KR'), AppLang.en);
      expect(L10n.langForLocale('ar-EG'), AppLang.en);
    });

    test('探测不到返回 null（由调用方决定回落）', () {
      expect(L10n.langForLocale(''), isNull);
      expect(L10n.langForLocale('   '), isNull);
      expect(L10n.langForLocale('C'), isNull);
    });

    test('apply 显式配置优先于系统', () {
      L10n.apply('en');
      expect(L10n.current, AppLang.en);
      L10n.apply('zh');
      expect(L10n.current, AppLang.zh);
    });
  });

  group('内置教程', () {
    test('两种语言都有内容且包含关键章节', () {
      expect(kTutorialZh.length, greaterThan(1500));
      expect(kTutorialEn.length, greaterThan(1500));
      for (final key in ['三种使用模式', '配置 API Key', '出图', '常见问题']) {
        expect(kTutorialZh.contains(key), isTrue, reason: '中文教程缺少「$key」');
      }
      for (final key in ['Three ways', 'API key', 'Render', 'FAQ']) {
        expect(kTutorialEn.toLowerCase().contains(key.toLowerCase()), isTrue,
            reason: '英文教程缺少「$key」');
      }
    });

    test('tutorialText() 跟随界面语言', () {
      L10n.setExplicit(AppLang.zh);
      expect(tutorialText(), startsWith('编制图生成器'));
      L10n.setExplicit(AppLang.en);
      expect(tutorialText(), startsWith('ORBAT Generator'));
      L10n.setExplicit(AppLang.zh);
    });

    test('教程里不出现未替换的占位符', () {
      for (final text in [kTutorialZh, kTutorialEn]) {
        expect(text.contains(r'$k'), isFalse);
        expect(text.contains('{'), isFalse);
      }
    });
  });
}
