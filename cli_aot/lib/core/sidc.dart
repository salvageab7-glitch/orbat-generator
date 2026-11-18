import 'sidc_entities.dart';
import 'sidc_tables.dart';

/// SIDC 构造 / 解析工具
///
/// 30 位码的分段（**0-based 索引**，与 milsymbol 3.0.4 实测一致）：
///   [0-1]   版本 = 13
///   [2-3]   上下文 / 标准 = 03
///   [4-5]   符号集：10=陆地单位、01=空中单位（**决定主实体码语义**）
///   [6-7]   状态 = 00
///   [8-9]   梯队   ← echelon
///   [10-15] 主实体 ← entity
///   [16-17] 类型修饰
///   [18-19] 机动修饰
///   [20-21] 扇区修饰
///   [22-29] 保留 = 00000000
class Sidc {
  final String symbolSet; // 2 位：10=陆地, 01=空中
  final String echelon; // 2 位
  final String entity; // 6 位
  final String typeMod; // 2 位
  final String mobilityMod; // 2 位
  final String sectorMod; // 2 位

  const Sidc({
    this.symbolSet = '10',
    required this.echelon,
    required this.entity,
    this.typeMod = '00',
    this.mobilityMod = '00',
    this.sectorMod = '00',
  });

  /// 生成 30 位 SIDC 字符串：1303 + 符号集 + 00 + 梯队 + 实体 + 类型 + 机动 + 扇区 + 保留
  String build() {
    return '1303$symbolSet'
        '00'
        '$echelon$entity$typeMod$mobilityMod$sectorMod'
        '00000000';
  }

  @override
  String toString() => build();

  /// 从 30 位码反解析。长度或字符不合法时返回 null。
  static Sidc? parse(String code) {
    if (code.length != 30) return null;
    if (!RegExp(r'^\d+$').hasMatch(code)) return null;
    return Sidc(
      symbolSet: code.substring(4, 6),
      echelon: code.substring(8, 10),
      entity: code.substring(10, 16),
      typeMod: code.substring(16, 18),
      mobilityMod: code.substring(18, 20),
      sectorMod: code.substring(20, 22),
    );
  }

  /// 该主实体码在对应符号集标准表中是否合法。
  bool get entityIsKnown {
    final table = switch (symbolSet) {
      '10' => kLandEntityFull,
      '01' => kAirEntityFull,
      _ => null,
    };
    if (table != null) return table.containsKey(entity);
    return kEntity.containsKey(entity);
  }

  /// 主实体码的人类可读名称（中文项目表优先，milsymbol 英文名兜底）
  String get entityName =>
      kEntity[entity] ??
      switch (symbolSet) {
        '10' => kLandEntityFull[entity],
        '01' => kAirEntityFull[entity],
        _ => null,
      } ??
      entity;

  /// 解读成人类可读文字
  String describe() {
    final e = kEchelon[echelon] ?? (echelon == '00' ? '未指定' : echelon);
    final t = kTypeModifier[typeMod] ?? typeMod;
    final m = kMobilityModifier[mobilityMod] ?? mobilityMod;
    final s = kSectorModifier[sectorMod] ?? sectorMod;
    final dim = symbolSet == '01' ? '空中' : (symbolSet == '10' ? '陆地' : symbolSet);
    return '$dim | $e | $entityName | 类型:$t | 机动:$m | 扇区:$s';
  }
}
