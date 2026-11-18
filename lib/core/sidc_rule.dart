/// 名称 → SIDC 规则引擎（本地）
///
/// 为什么要有这个：
/// 实测把「构造 30 位 SIDC」和「读图」塞给模型一次做完时，读图精度会明显下降——
/// 同一张图块，只问"列出单位名称"能 11 个单位全对；带上完整的 SIDC 规范去问，
/// 就会出现「第1MT连」这种截断、以及「无法识别」占位。
///
/// 所以拆成两件事：
///   模型：只负责读名字和层级（它擅长的）
///   本地：由这个规则引擎生成 SIDC（可以做到 100% 合规、一致）
///
/// 规则来自 `reference/sidc-codes.md` 与项目既有编制档案的惯例。
library;

import 'sidc_tables.dart';

/// 一次推断结果
class SidcGuess {
  final String sidc;
  final String echelon;
  final String entity;
  final String typeMod;
  final String mobility;
  final String reason;

  const SidcGuess({
    required this.sidc,
    required this.echelon,
    required this.entity,
    required this.typeMod,
    required this.mobility,
    required this.reason,
  });
}

class SidcRule {
  /// 从单位名称推断 30 位 SIDC
  ///
  /// [echelonOverride] 用于骨架已确定层级时强制使用（比从名字猜更可靠）
  static SidcGuess fromName(String name, {String? echelonOverride}) {
    final echelon = echelonOverride ?? guessEchelon(name);
    final arm = _guessArm(name);

    // 1303 + 符号集10 + 00 + 梯队2 + 实体6 + 类型2 + 机动2 + 扇区2 + 保留8
    final sidc = '1303'
        '10'
        '00'
        '$echelon'
        '${arm.entity}'
        '${arm.typeMod}'
        '${arm.mobility}'
        '00'
        '00000000';

    return SidcGuess(
      sidc: sidc,
      echelon: echelon,
      entity: arm.entity,
      typeMod: arm.typeMod,
      mobility: arm.mobility,
      reason: arm.reason,
    );
  }

  /// 从名称里的层级词判断梯队码
  static String guessEchelon(String name) {
    if (name.contains('方面军') || name.contains('战区')) return '25';
    if (name.contains('集团军群')) return '24';
    if (name.contains('集团军')) return '23';
    if (name.contains('军区')) return '25';
    if (name.contains('师') && !name.contains('师部')) return '21';
    if (name.contains('旅') && !name.contains('旅部')) return '18';
    if (name.contains('团') && !name.contains('团部')) return '17';
    if (name.contains('营') && !name.contains('营部')) return '16';
    if (name.contains('连') && !name.contains('连部')) return '15';
    if (name.contains('排')) return '14';
    if (name.contains('班')) return '12';
    if (name.contains('组')) return '13';

    // 「XX部」「司令部」「指挥部」类通常是上级的指挥机构
    if (name.endsWith('部') || name.contains('司令部') || name.contains('指挥部')) {
      return '15'; // 默认按连级指挥所
    }
    return '00';
  }

  /// 从名称判断兵种/职能，返回实体码 + 类型修饰 + 机动修饰
  static _Arm _guessArm(String name) {
    final n = name;

    // ---- 指挥机构（最优先，避免"炮兵营部"被当成炮兵）----
    if (n.endsWith('营部') ||
        n.endsWith('旅部') ||
        n.endsWith('团部') ||
        n.endsWith('师部') ||
        n.contains('司令部') ||
        n.contains('指挥部') ||
        n.contains('旅部及旅部连')) {
      return const _Arm('110000', '00', '00', '指挥机构');
    }

    // ---- 火箭炮（须在普通炮兵之前判断）----
    if (n.contains('火箭炮') ||
        n.contains('火箭') ||
        n.contains('Град') ||
        n.contains('БМ-') ||
        n.contains('Ураган') ||
        n.contains('Смерч')) {
      return const _Arm('130300', '41', '04', '多管火箭炮');
    }

    // ---- 反坦克导弹（须在普通反坦克之前）----
    if (n.contains('反坦克导弹') ||
        n.contains('ПТРК') ||
        n.contains('Конкурс') ||
        n.contains('9К') ||
        n.contains('Штурм') ||
        n.contains('Фагот') ||
        n.contains('Малютка')) {
      return const _Arm('120400', '37', '00', '反坦克导弹');
    }

    // ---- 反坦克（火炮/通用）----
    if (n.contains('反坦克') || n.contains('МТ-12') || n.contains('СПГ')) {
      return const _Arm('120400', '00', '00', '反坦克');
    }

    // ---- 迫击炮（须在炮兵之前）----
    if (n.contains('迫击炮') || n.contains('2С9') || n.contains('2Б') || n.contains('Миномёт')) {
      return const _Arm('130800', '12', '00', '迫击炮');
    }

    // ---- 自行火炮 ----
    if (n.contains('自行火炮') ||
        n.contains('2С1') ||
        n.contains('2С3') ||
        n.contains('2С19') ||
        n.contains('自行炮')) {
      return const _Arm('130300', '00', '04', '自行火炮');
    }

    // ---- 炮兵（牵引/通用）----
    if (n.contains('炮兵') ||
        n.contains('榴弹炮') ||
        n.contains('加农炮') ||
        n.contains('火炮') ||
        n.contains('炮连')) {
      return const _Arm('130300', '00', '00', '炮兵');
    }

    // ---- 防空 ----
    if (n.contains('防空') ||
        n.contains('高炮') ||
        n.contains('ЗСУ') ||
        n.contains('Стрела') ||
        n.contains('Оса') ||
        n.contains('Тор') ||
        n.contains('Бук')) {
      final selfPropelled = n.contains('自行') || n.contains('ЗСУ');
      return _Arm('130101', '00', selfPropelled ? '23' : '00', '防空');
    }

    // ---- 坦克/装甲 ----
    if (n.contains('坦克') ||
        n.contains('装甲') ||
        n.contains('Т-5') ||
        n.contains('Т-6') ||
        n.contains('Т-7') ||
        n.contains('Т-8') ||
        n.contains('ПТ-76')) {
      return const _Arm('120500', '00', '00', '装甲/坦克');
    }

    // ---- 自动榴弹发射器（须在步兵之前）----
    if (n.contains('АГС') || n.contains('自动榴弹')) {
      return const _Arm('121100', '56', '00', '自动榴弹发射器');
    }

    // ---- 侦察 ----
    if (n.contains('侦察') || n.contains('情报') || n.contains('搜索')) {
      return const _Arm('121300', '00', '00', '侦察');
    }

    // ---- 工兵 ----
    if (n.contains('工兵') || n.contains('工程') || n.contains('舟桥') || n.contains('排爆')) {
      return const _Arm('140700', '00', '00', '工兵');
    }

    // ---- 通信 ----
    if (n.contains('通信') || n.contains('信号') || n.contains('通讯')) {
      return const _Arm('111000', '00', '00', '通信');
    }

    // ---- 医疗 ----
    if (n.contains('医疗') || n.contains('卫生') || n.contains('医院')) {
      return const _Arm('160800', '00', '00', '医疗');
    }

    // ---- 后勤/保障 ----
    if (n.contains('保障') ||
        n.contains('后勤') ||
        n.contains('运输') ||
        n.contains('补给') ||
        n.contains('维修') ||
        n.contains('修理') ||
        n.contains('弹药') ||
        n.contains('物资')) {
      return const _Arm('160000', '00', '00', '后勤保障');
    }

    // ---- 海军陆战 / 步兵（兜底：编制图里最常见的兵种）----
    if (n.contains('陆战') ||
        n.contains('步兵') ||
        n.contains('摩托化') ||
        n.contains('机械化') ||
        n.contains('猎兵') ||
        n.contains('伞兵') ||
        n.contains('空降')) {
      final amphibious = n.contains('陆战') || n.contains('海军');
      return _Arm('121100', '00', amphibious ? '60' : '00', '步兵');
    }

    // ---- 完全判断不出来：用通用指挥标志，避免瞎编 ----
    return const _Arm('000000', '00', '00', '未能判断兵种');
  }
}

class _Arm {
  final String entity;
  final String typeMod;
  final String mobility;
  final String reason;

  const _Arm(this.entity, this.typeMod, this.mobility, this.reason);
}

/// 供 UI 提示：这个名称最终会用什么码
String explainSidc(String name) {
  final g = SidcRule.fromName(name);
  final e = kEchelon[g.echelon] ?? g.echelon;
  final en = kEntity[g.entity] ?? g.entity;
  return '$e | $en | ${g.reason}';
}
