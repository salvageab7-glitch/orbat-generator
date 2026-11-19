/// 核心引擎自检：不依赖 flutter / pub 包，直接 dart run
import 'dart:io';
import 'package:orbat_core/core/sidc.dart';
import 'package:orbat_core/core/orbat.dart';

void main() {
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

  print('=== 1. SIDC 构造 ===');
  const s = Sidc(echelon: '18', entity: '121100', mobilityMod: '13');
  final code = s.build();
  check('长度=30', code.length == 30);
  check('版本位13', code.substring(0, 2) == '13');
  check('梯队位=18', code.substring(8, 10) == '18');
  check('主实体=121100', code.substring(10, 16) == '121100');
  check('机动=13', code.substring(18, 20) == '13');
  check('保留位全0', code.substring(22) == '00000000');
  print('  code=$code');
  print('  desc=${s.describe()}');

  print('=== 2. SIDC 解析往返 ===');
  final parsed = Sidc.parse(code);
  check('解析非空', parsed != null);
  check('往返一致', parsed!.build() == code);
  check('拒绝错误长度', Sidc.parse('123') == null);

  print('=== 3. 与你现有真实 JSON 对照 ===');
  // 用脚本生成的那棵树做一次内存构造校验（山地步兵旅）
  final root = OrbatNode(
    uniqueDesignation: '山地步兵旅',
    additionalInformation: '旅级·三级格局',
    sidc: Sidc(echelon: '18', entity: '121100', mobilityMod: '13').build(),
    children: [
      OrbatNode(
        uniqueDesignation: '旅部营',
        additionalInformation: '旅司令部及旅部连',
        sidc: Sidc(echelon: '16', entity: '110000').build(),
      ),
      OrbatNode(
        uniqueDesignation: '山地步兵营×3',
        additionalInformation: '三个营编制相同',
        sidc: Sidc(echelon: '16', entity: '121100', mobilityMod: '13').build(),
      ),
      OrbatNode(
        uniqueDesignation: '旅属炮兵营',
        additionalInformation: '旅属火炮',
        sidc: Sidc(echelon: '16', entity: '130300').build(),
      ),
    ],
  );
  final report = OrbatValidator.validate(root);
  check('真实树无红牌', report.ok);
  print(report.toString());

  print('=== 4. 红牌规则命中测试 ===');
  final bad = OrbatNode(
    uniqueDesignation: '某连 (测试)', // 空格+括号 → 红牌
    additionalInformation: '这是一段超长的注释文字用来测试超过二十四个汉字的红牌规则是否生效啊啊啊',
    sidc: '1303100015121105000000000000000', // 31位 → 红牌
  );
  final badReport = OrbatValidator.validate(bad);
  check('空格+括号被拦', badReport.issues.any((i) => i.message.contains('空格+左括号')));
  check('超长注释被拦', badReport.issues.any((i) => i.message.contains('注释超长')));
  check('错误长度被拦', badReport.issues.any((i) => i.message.contains('必须 30 位')));
  check('红牌数>0', !badReport.ok);
  print(badReport.toString());

  print('=== 5. 7键归一化 ===');
  final normalized = normalizeTree(root, commandLevels: '1');
  check('根有commandLevels', normalized['commandLevels'] == '1');
  final rootOpts = normalized['options'] as Map;
  check('options恰好7键', rootOpts.length == 7);
  check('含showMapLabels', rootOpts.containsKey('showMapLabels'));
  final child = (normalized['subOrganizations'] as List).first as Map;
  check('子节点无commandLevels', !child.containsKey('commandLevels'));

  print('=== 6. 110000 mod98 拦截 ===');
  final hqBad = OrbatNode(
    uniqueDesignation: '旅部',
    additionalInformation: 'HQ',
    sidc: Sidc(echelon: '18', entity: '110000', typeMod: '98').build(),
  );
  check('HQ加98被拦',
      OrbatValidator.validate(hqBad).issues.any((i) => i.message.contains('禁止加类型修饰 98')));

  print('=== 7. 符号集分支（陆地10 / 空中01）===');
  // 空中运输机：符号集 01，前缀 13030100
  final airTransport = Sidc(
      symbolSet: '01', echelon: '11', entity: '110107');
  check('空中码前缀=13030100', airTransport.build().startsWith('13030100'));
  check('空中码长度30', airTransport.build().length == 30);
  final airParsed = Sidc.parse(airTransport.build())!;
  check('空中符号集往返', airParsed.symbolSet == '01');
  check('空中主实体往返', airParsed.entity == '110107');
  check('空中码在标准表内', airParsed.entityIsKnown);
  check('空中码解读为Cargo', airParsed.describe().contains('Cargo'));

  // 陆地步兵：符号集 10，前缀 13031000
  final landInf = Sidc(symbolSet: '10', echelon: '16', entity: '121100');
  check('陆地码前缀=13031000', landInf.build().startsWith('13031000'));
  check('陆地码在标准表内', Sidc.parse(landInf.build())!.entityIsKnown);

  // 同码不同义：110400 在陆地=信息作战，在空中=垂直起降无人机
  final land400 = Sidc.parse('130310001511040000000000000000')!;
  final air400 = Sidc.parse('130301001111040000000000000000')!;
  check('110400陆空解读不同', land400.entityName != air400.entityName);

  // 编造的码应被判未知
  final bogus = Sidc.parse('130310001699999900000000000000')!;
  check('编造码被判未知', !bogus.entityIsKnown);

  // 000000 通用指挥：标准表无此码但项目约定合法，校验器应放行
  final generic = OrbatNode(
    uniqueDesignation: '联合特遣部队',
    additionalInformation: 'JTF',
    sidc: '130310001500000000000000000000',
  );
  check('000000通用码不放warn',
      !OrbatValidator.validate(generic).issues.any((i) => i.message.contains('不在符号集')));

  print('\n=== 结果: PASS $pass / FAIL $fail ===');
  if (fail > 0) exitCode = 1;
}
