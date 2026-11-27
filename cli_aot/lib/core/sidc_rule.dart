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
  ///
  /// v0.4 修正：改成**取最靠右的层级词**（中文与外文统一）。
  /// 原因：编制单位名是"修饰语 + 中心词"结构，中心词在最后——
  /// 「第2师通信团」必须判成团(17)，按老规则（词表顺序优先师）会判成师(21)，
  /// 于是图画成师级方框、校验器还查不出来。测试用例见 v04_rules_test.dart。
  static String guessEchelon(String name) {
    final t = _effectiveEchelonName(name.trim());
    if (t.isEmpty) return '00';

    final base = _echelonFromWords(t);
    final lower = t.toLowerCase();

    // 指挥所（XX部 / 司令部 / HQ）：按惯例比本级低一级
    //   连部 15→14、营/团/旅部 16/17/18→15（旅部及旅部连这类以"连"结尾的不算部）
    //   师及以上本级没有更低一级的合法码（19/20 禁用），沿用本级
    final isHq = t.endsWith('部') ||
        t.contains('司令部') ||
        t.contains('指挥部') ||
        _hqRe.hasMatch(lower);
    if (!isHq) return base;

    return switch (base) {
      '21' || '22' || '23' || '24' || '25' => base,
      '15' => '14',
      '14' => '13',
      '16' || '17' || '18' => '15',
      _ => '15',
    };
  }

  /// 层级词是否落在名称尾部（最后一个词附近）。
  ///
  /// 用途：一致性审计只在"尾部有层级词"时才敢按名称改梯队码。
  /// 反例：「2nd Division Postal Unit」——开头有 Division，但它是**母体名**，
  /// 单位本身是连级；若照 Division 改成师级，会把对的结果改错。
  static bool echelonAtTail(String name) {
    final t = _effectiveEchelonName(name.trim());
    if (t.isEmpty) return false;
    if (t.endsWith('部') || t.contains('司令部') || t.contains('指挥部')) {
      return true;
    }
    if (_hqRe.hasMatch(t.toLowerCase())) return true;
    final cands = _echelonCandidates(t);
    if (cands.isEmpty) return false;
    final kept = _dropContained(cands);
    kept.sort((a, b) => b.at.compareTo(a.at));
    final last = kept.first;

    // 匹配之后剩下的部分：去掉括号内容（如 "(Helicopter)"）后只允许很少的尾缀，
    // 且不能再含层级词——否则说明层级词在中间，它修饰的是母体名而不是本单位。
    var suffix = t.substring(last.at + last.len);
    suffix = suffix.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
    suffix = suffix.replaceAll(RegExp(r'[\s·\-—,，、]+$'), '');
    // 只认"层级词之后什么都没有"的名称（括号内容已剥掉）。
    // 例如 "2nd Division RAA"（师属炮兵）后面还有缩写，不能因为开头有 Division
    // 就改成师级——宁可不动，也不要把对的改错。
    return suffix.isEmpty;
  }

  /// 「第1营·第327步兵团」这类名称：· 前是本单位，· 后是母体番号。
  /// 若 · 前的层级明显低于 · 后，返回前半段；否则保留全名。
  /// 这样既能把“第1营·第327步兵团”判成营，又不会把“第101空降师·师部”判错。
  static String _effectiveEchelonName(String t) {
    final sep = t.indexOf('·');
    if (sep <= 0) return t;
    final head = t.substring(0, sep).trim();
    final tail = t.substring(sep + 1).trim();
    if (head.isEmpty || tail.isEmpty) return t;
    final h = _echelonFromWords(head);
    final l = _echelonFromWords(tail);
    final hr = _echelonRank[h];
    final lr = _echelonRank[l];
    if (hr == null || lr == null || hr >= lr) return t;
    return head;
  }

  /// 层级码秩：数字越大层级越高，用于比较 · 前后两段。
  static const Map<String, int> _echelonRank = {
    '11': 1,
    '12': 2,
    '13': 3,
    '14': 4,
    '15': 5,
    '16': 6,
    '17': 7,
    '18': 8,
    '21': 9,
    '22': 10,
    '23': 11,
    '24': 12,
    '25': 13,
    '26': 14,
  };

  /// 只按"最靠右的层级词"判层级，不处理指挥所
  static String _echelonFromWords(String t) {
    final cands = _echelonCandidates(t);
    if (cands.isEmpty) return '00';
    final kept = _dropContained(cands);
    kept.sort((a, b) {
      final byAt = b.at.compareTo(a.at);
      return byAt != 0 ? byAt : b.len.compareTo(a.len);
    });
    return kept.first.code;
  }

  /// 收集所有层级词命中（中文 + 外文）
  static List<({int at, int len, String code})> _echelonCandidates(String t) {
    final candidates = <({int at, int len, String code})>[];
    for (final (word, code) in _cjkEchelonWords) {
      var i = t.indexOf(word);
      while (i >= 0) {
        candidates.add((at: i, len: word.length, code: code));
        i = t.indexOf(word, i + 1);
      }
    }
    final lower = t.toLowerCase();
    for (final (re, code) in _foreignEchelonRules) {
      for (final m in re.allMatches(lower)) {
        candidates.add((at: m.start, len: m.end - m.start, code: code));
      }
    }
    return candidates;
  }

  /// 去掉被更长命中包含的短词（「集团军」里的「军」、「division」里的「div」）
  static List<({int at, int len, String code})> _dropContained(
      List<({int at, int len, String code})> cands) {
    final kept = <({int at, int len, String code})>[];
    for (final c in cands) {
      final inside = cands.any(
          (o) => o.len > c.len && o.at <= c.at && o.at + o.len >= c.at + c.len);
      if (!inside) kept.add(c);
    }
    return kept;
  }

  /// 中文层级词表（含复合词，靠"最右 + 去包含"消歧）
  static const List<(String, String)> _cjkEchelonWords = [
    ('方面军', '25'),
    ('战区', '25'),
    ('军区', '25'),
    ('集团军群', '24'),
    ('集团军', '23'),
    ('师', '21'),
    ('旅', '18'),
    ('团', '17'),
    ('营', '16'),
    ('连', '15'),
    ('排', '14'),
    ('班', '12'),
    ('组', '13'),
  ];

  /// 外文 HQ 判定（英文/俄文）
  static final RegExp _hqRe =
      RegExp(r'\b(hq|hqs|headquarter|headquarters|command post|staff)\b|штаб');

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

    // ---- 外文兵种词（v0.4）：原文模式下名称是英/俄文 ----
    final foreign = _foreignArm(n);
    if (foreign != null) return foreign;

    // ---- 火箭炮（站点无独立实体码；修饰位已禁用，统一用 130300 靠名称区分）----
    if (n.contains('火箭炮') ||
        n.contains('火箭') ||
        n.contains('Град') ||
        n.contains('БМ-') ||
        n.contains('Ураган') ||
        n.contains('Смерч')) {
      return const _Arm('130300', '00', '00', '火箭炮(名称区分)');
    }

    // ---- 反坦克导弹（须在普通反坦克之前）----
    if (n.contains('反坦克导弹') ||
        n.contains('ПТРК') ||
        n.contains('Конкурс') ||
        n.contains('9К') ||
        n.contains('Штурм') ||
        n.contains('Фагот') ||
        n.contains('Малютка')) {
      return const _Arm('120400', '00', '00', '反坦克导弹');
    }

    // ---- 反坦克（火炮/通用）----
    if (n.contains('反坦克') || n.contains('МТ-12') || n.contains('СПГ')) {
      return const _Arm('120400', '00', '00', '反坦克');
    }

    // ---- 迫击炮（须在炮兵之前）----
    if (n.contains('迫击炮') ||
        n.contains('2С9') ||
        n.contains('2Б') ||
        n.contains('Миномёт')) {
      return const _Arm('130800', '00', '00', '迫击炮');
    }

    // ---- 自行火炮（履带式，130301；站点权威语义）----
    if (n.contains('自行火炮') ||
        n.contains('2С1') ||
        n.contains('2С3') ||
        n.contains('2С19') ||
        n.contains('自行炮')) {
      return const _Arm('130301', '00', '00', '自行火炮(履带)');
    }

    // ---- 炮兵侦察/观察（须在普通炮兵之前，站点 130400）----
    if (n.contains('炮兵侦察') ||
        n.contains('炮兵观察') ||
        n.contains('炮观') ||
        n.contains('前方观察')) {
      return const _Arm('130400', '00', '00', '炮兵侦察/观察');
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

    // ---- 战役战术导弹（须在防空之后，避免“防空导弹”被当成通用导弹）----
    if (n.contains('战役战术导弹') ||
        n.contains('战术导弹') ||
        n.contains('导弹旅') ||
        n.contains('导弹营') ||
        n.contains('导弹连') ||
        n.contains('导弹分队')) {
      return const _Arm('130700', '00', '00', '战役战术导弹');
    }

    // ---- 空中骑兵 / 航空支援（陆军航空）----
    if (n.contains('空中骑兵') ||
        n.contains('空中机动') ||
        n.contains('航空支援') ||
        n.contains('航空连')) {
      return const _Arm('120600', '00', '00', '空中骑兵/航空支援');
    }

    // ---- 步兵战车 IFV / 装甲步兵（须在坦克之前，避免"装甲步兵"被判成坦克）----
    if (n.contains('步兵战车') || n.contains('步战车')) {
      return const _Arm('121105', '00', '00', '步兵战车IFV');
    }
    if (n.contains('装甲步兵') || n.contains('机械步兵')) {
      return const _Arm('121102', '00', '00', '装甲机械化');
    }

    // ---- 装甲列车（站点无独立实体码，按装甲处理并用名称区分）----
    if (n.contains('装甲列车') || n.contains('装甲火车') || n.contains('列车炮')) {
      return const _Arm('120500', '00', '00', '装甲列车(按装甲处理)');
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
      return const _Arm('121100', '00', '00', '自动榴弹发射器');
    }

    // ---- 反情报 / 电子战 / 雷达（须在通用侦察之前）----
    if (n.contains('反情报')) {
      return const _Arm('150200', '00', '00', '反情报');
    }
    if (n.contains('电子战')) {
      return const _Arm('150500', '00', '00', '电子战');
    }
    if (n.contains('雷达')) {
      return const _Arm('121600', '00', '00', '雷达站(监视)');
    }
    if (n.contains('联络')) {
      return const _Arm('110500', '00', '00', '联络');
    }
    // ---- 侦察 ----
    if (n.contains('侦察') || n.contains('情报') || n.contains('搜索')) {
      return const _Arm('121300', '00', '00', '侦察');
    }

    // ---- 工兵 ----
    if (n.contains('工兵') ||
        n.contains('工程') ||
        n.contains('舟桥') ||
        n.contains('排爆')) {
      return const _Arm('140700', '00', '00', '工兵');
    }

    // ---- 通信 ----
    if (n.contains('通信') || n.contains('信号') || n.contains('通讯')) {
      return const _Arm('111000', '00', '00', '通信');
    }

    // ---- 医疗/卫生（161300；站点 Medical，中国称卫生单位）----
    if (n.contains('医疗') || n.contains('卫生') || n.contains('医院')) {
      return const _Arm('161300', '00', '00', '医疗/卫生');
    }

    // ---- 雷达站/雷达连（121600 监视；站点单位集无独立雷达码）----
    if (n.contains('雷达')) {
      return const _Arm('121600', '00', '00', '雷达站(监视)');
    }

    // ---- 军法署（160800；站点 Judge Advocate General）----
    if (n.contains('军法')) {
      return const _Arm('160800', '00', '00', '军法署');
    }

    // ---- 人事/副官署（165600 Human Resources）----
    if (n.contains('副官') ||
        n.contains('人事') ||
        n.contains('人力资源') ||
        RegExp(r'\bHR\b').hasMatch(n)) {
      return const _Arm('165600', '00', '00', '人事/副官署');
    }

    // ---- 军需（162900 Quartermaster）----
    if (n.contains('军需') || n.contains('粮秣')) {
      return const _Arm('162900', '00', '00', '军需');
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

    // ---- 步兵类（站点语义细分）----
    // 步兵战车 IFV → 121105；装甲/机械化 → 121102；摩托化 → 121104；其余步兵 → 121100
    final amphibious = n.contains('陆战') || n.contains('海军');
    if (n.contains('步兵战车') || n.contains('步战车')) {
      return const _Arm('121105', '00', '00', '步兵战车IFV');
    }
    if (n.contains('装甲步兵') || n.contains('机械化') || n.contains('装甲机械')) {
      return const _Arm('121102', '00', '00', '装甲机械化');
    }
    if (n.contains('摩托化')) {
      return const _Arm('121104', '00', '00', '摩托化步兵');
    }
    if (amphibious ||
        n.contains('步兵') ||
        n.contains('猎兵') ||
        n.contains('伞兵') ||
        n.contains('空降')) {
      return _Arm('121100', '00', amphibious ? '60' : '00', '步兵');
    }

    // ---- 完全判断不出来：用通用指挥标志，避免瞎编 ----
    return const _Arm('000000', '00', '00', '未能判断兵种');
  }
}

/// 外文层级词规则（正则 → 梯队码）
///
/// 顺序不再决定优先级——`guessEchelon` 统一取最靠右的层级词，
/// 所以 "2nd Division Signals Regiment" 会正确判成团(17)而不是师(21)。
final List<(RegExp, String)> _foreignEchelonRules = [
  (RegExp(r'theater|theatre|\bfront\b'), '25'),
  (RegExp(r'army group|front group'), '24'),
  (RegExp(r'group army|combined arms army'), '23'),
  (RegExp(r'\barmy\b|\bcorps\b|корпус'), '22'),
  (RegExp(r'division|дивизи|\bdiv\b'), '21'),
  (RegExp(r'brigade|бригад|\bbde\b'), '18'),
  (RegExp(r'regiment|полк|\brgt\b'), '17'),
  (RegExp(r'battalion|батальон|\bbn\b|\bbatt\b'), '16'),
  (RegExp(r'squadron|эскадриль|\bsqn\b'), '16'),
  (RegExp(r'company|рота|батаре|battery|\bcoy\b'), '15'),
  (RegExp(r'platoon|взвод|\bplt\b'), '14'),
  (RegExp(r'\btroop\b'), '14'),
  (RegExp(r'\bsquad\b|отделен'), '12'),
  (RegExp(r'\bteam\b|\bcrew\b'), '13'),
];

/// 外文兵种词 → 主实体码（与中文规则一一对应，顺序同样重要）
_Arm? _foreignArm(String raw) {
  final s = raw.toLowerCase();

  // 指挥机构
  if (RegExp(r'headquarter|\bhq\b|command post|\bstaff\b|штаб').hasMatch(s)) {
    return const _Arm('110000', '00', '00', '指挥机构(en)');
  }
  // 火箭炮 / 多管火箭
  if (RegExp(r'\bmlrs\b|rocket|град|ураган|смерч').hasMatch(s)) {
    return const _Arm('130300', '00', '00', '多管火箭炮(en)');
  }
  // 反坦克导弹
  if (RegExp(r'anti-?tank missile|\batgm\b|птур|конкурс|фагот|малютка')
      .hasMatch(s)) {
    return const _Arm('120400', '00', '00', '反坦克导弹(en)');
  }
  // 反坦克（通用）
  if (RegExp(r'anti-?tank|противотанк').hasMatch(s)) {
    return const _Arm('120400', '00', '00', '反坦克(en)');
  }
  // 迫击炮
  if (RegExp(r'mortar|миномёт|миномет').hasMatch(s)) {
    return const _Arm('130800', '00', '00', '迫击炮(en)');
  }
  // 自行火炮（履带式，130301）
  if (RegExp(r'self-?propelled|самоходн').hasMatch(s) &&
      RegExp(r'artillery|gun|гаубиц|артиллер').hasMatch(s)) {
    return const _Arm('130301', '00', '00', '自行火炮履带(en)');
  }
  // 炮兵
  if (RegExp(r'artillery|howitzer|артиллер|гаубиц').hasMatch(s)) {
    return const _Arm('130300', '00', '00', '炮兵(en)');
  }
  // 防空
  if (RegExp(r'air ?defen[cs]e|\bsam\b|\baaa\b|пво|зенит').hasMatch(s)) {
    return const _Arm('130101', '00', '00', '防空(en)');
  }
  // 装甲列车（站点无独立实体码，按装甲处理）
  if (RegExp(r'armou?red train|railway gun|railroad gun').hasMatch(s)) {
    return const _Arm('120500', '00', '00', '装甲列车(en)');
  }
  // 战役战术导弹（通用导弹；防空导弹已在上方处理）
  if (RegExp(
          r'theater missile|tactical missile|missile (brigade|battalion|company|detachment)|missile unit')
      .hasMatch(s)) {
    return const _Arm('130700', '00', '00', '战役战术导弹(en)');
  }
  // 空中骑兵 / 航空支援（陆军航空）
  if (RegExp(r'air cavalry|air assault|aviation support|aviation company')
      .hasMatch(s)) {
    return const _Arm('120600', '00', '00', '空中骑兵/航空支援(en)');
  }
  // 装甲 / 坦克
  if (RegExp(r'\btank\b|armou?red|бронетанк|танков').hasMatch(s)) {
    return const _Arm('120500', '00', '00', '装甲坦克(en)');
  }
  // 侦察
  if (RegExp(r'recon|scout|развед').hasMatch(s)) {
    return const _Arm('121300', '00', '00', '侦察(en)');
  }
  // 工兵
  if (RegExp(r'engineer|сапёр|сапер|инженер').hasMatch(s)) {
    return const _Arm('140700', '00', '00', '工兵(en)');
  }
  // 通信
  if (RegExp(r'signal|communication|связ').hasMatch(s)) {
    return const _Arm('111000', '00', '00', '通信(en)');
  }
  // 医疗/卫生（161300）
  if (RegExp(r'medical|medical company|hospital|медицин|sanitary')
      .hasMatch(s)) {
    return const _Arm('161300', '00', '00', '医疗/卫生(en)');
  }
  // 雷达站（121600 监视）
  if (RegExp(r'\bradar\b|радиолокац|\brtr\b').hasMatch(s)) {
    return const _Arm('121600', '00', '00', '雷达站(en)');
  }
  // 军法署（160800）
  if (RegExp(r'judge advocate|\bjag\b|военн?ый суд').hasMatch(s)) {
    return const _Arm('160800', '00', '00', '军法署(en)');
  }
  // 人事/副官署（165600）
  if (RegExp(r'adjutant|human resources|\bhr\b|personnel').hasMatch(s)) {
    return const _Arm('165600', '00', '00', '人事/副官署(en)');
  }
  // 军需（162900）
  if (RegExp(r'quartermaster|supply (company|battalion|depot)').hasMatch(s)) {
    return const _Arm('162900', '00', '00', '军需(en)');
  }
  // 后勤 / 保障
  if (RegExp(r'supply|logistic|transport|maintenance|снабж|ремонт|транспорт')
      .hasMatch(s)) {
    return const _Arm('160000', '00', '00', '后勤保障(en)');
  }
  // 陆军航空兵（陆地符号集，实体 120600）
  if (RegExp(r'army aviation|aviation regiment|陆军航空').hasMatch(s)) {
    return const _Arm('120600', '00', '00', '陆军航空兵(en)');
  }
  // 步兵战车 IFV（站点 121105）
  if (RegExp(r'infantry fighting vehicle|\bifv\b|\bbmp\b|marder|步兵战车')
      .hasMatch(s)) {
    return const _Arm('121105', '00', '00', '步兵战车IFV(en)');
  }
  // 装甲/机械化（履带，站点 121102）
  if (RegExp(r'mechani[sz]ed|armoured? infantry|панцер|бронетранспорт')
      .hasMatch(s)) {
    return const _Arm('121102', '00', '00', '装甲机械化(en)');
  }
  // 摩托化步兵（站点 121104）
  if (RegExp(r'motor ?rifle|motorized|мотострелк').hasMatch(s)) {
    return const _Arm('121104', '00', '00', '摩托化步兵(en)');
  }
  // 步兵 / 空降 / 陆战（通用 121100）
  if (RegExp(r'infantry|marine|airborne|paratroop|rifle|пехот|десант|морск')
      .hasMatch(s)) {
    final amphibious = RegExp(r'marine|морск').hasMatch(s);
    return _Arm('121100', '00', amphibious ? '60' : '00', '步兵(en)');
  }
  return null;
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
