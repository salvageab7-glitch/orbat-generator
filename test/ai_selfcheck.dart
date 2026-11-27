/// AI 模块离线自检：不联网、不花钱
import 'package:orbat_core/ai/prompt.dart';
import 'package:orbat_core/ai/deepseek_client.dart';

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

  print('=== 1. extractJson 各种包裹 ===');
  check('纯JSON', extractJson('{"a":1}') == '{"a":1}');
  check('markdown json代码块', extractJson('```json\n{"a":1}\n```') == '{"a":1}');
  check('前后有解释文字', extractJson('这是结果：\n{"a":1}\n希望有用') == '{"a":1}');
  check('纯空格content', extractJson('   ') == '');

  print('=== 2. system prompt 关键规则齐全 ===');
  check('含30位SIDC公式', kOrbatSystemPrompt.contains('13031000'));
  check('含梯队码', kOrbatSystemPrompt.contains('18旅'));
  check('含修饰位禁用规则', kOrbatSystemPrompt.contains('修饰位全部禁用'));
  check('含编号单位铁律', kOrbatSystemPrompt.contains('严禁合并'));
  check('含空格加括号禁忌', kOrbatSystemPrompt.contains('空格+左括号'));
  check('含注释≤12', kOrbatSystemPrompt.contains('≤12 个汉字'));
  check('要求JSON输出', kOrbatSystemPrompt.contains('只输出一个合法 JSON'));
  check('含commandLevels', kOrbatSystemPrompt.contains('commandLevels'));

  print('=== 3. 用户消息构造 ===');
  check('图片模式有提示', buildUserMessage(hasImage: true).contains('编制图'));
  check('文字模式带上文字', buildUserMessage(text: '山地步兵旅编制').contains('山地步兵旅'));
  check('空输入有兜底', buildUserMessage().contains('编制 JSON'));

  print('\n=== 结果: PASS $pass / FAIL $fail ===');
}
