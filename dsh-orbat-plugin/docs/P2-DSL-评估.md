# P2：ORBAT DSL / SIDC 编译器可行性评估

> 范围：把“模型手写 30 位 SIDC”改为“模型只写单位名 + 类型 + 梯队，由插件编译 SIDC”。
> 结论：**可行，但应做成“渐进式编译器”，不要一上来做完整 DSL**。先做类型/梯队 → SIDC 的确定性映射，再视收益决定是否扩成 DSL。

## 1. 现状与真正的痛点

当前每个节点由模型手写：

```json
"sidc": "130310001612110000000000000000"
```

- 30 位里只有 **梯队 2 位 + 主实体 6 位** 有信息量，其余 15 位固定为 0。
- 模型最容易错的是：长度少一位、实体码记错、把修饰位写成非 0、HQ 加了 `98`。
- 这些错误 `orbat_validate_json` 能拦住，但要**多一轮校验 + 多一轮修正**；每次修正都要重发整棵树，token 成本远大于 SIDC 字符串本身。
- 另一个隐性成本是查码：模型为了确认实体码，会去翻 `reference/sidc-codes.md` 或跑 `sidc.js find`，一次就是几千 token。

**因此 P2 的价值不在“少写 30 个字符”，而在“消灭查码和返工”。**

## 2. 建议的 DSL 形态

最小 DSL（推荐先做这个）：

```yaml
name: 第101空降师
type: airborne_division
echelon: division
children:
  - name: 第1机动旅战斗队
    type: infantry_brigade
    echelon: brigade
    children:
      - name: 第1营
        type: infantry_battalion
        echelon: battalion
```

编译器负责：

1. `type` → 6 位主实体码。
2. `echelon` → 2 位梯队码。
3. 拼成 `13031000 + <echelon> + <entity> + 14 个 0`。
4. 输出标准 7 键 ORBAT JSON，再走现有 `validate` / `render`。

保留逃生口：

```yaml
name: 某特殊单位
sidc: "130310001612110000000000000000"   # 显式 SIDC 优先，type/echelon 可省略
```

这样模型在遇到未收录类型时不会被卡死，也不会被迫猜码。

## 3. 工具面设计（两种，推荐 B）

**A. 新增 `orbat_compile_dsl`**
- 输入 DSL，输出 JSON；再多一次工具调用。
- 适合调试，但会多一轮 round-trip，省下的 token 可能被抵消。

**B. 扩展现有工具（推荐）**
- `orbat_validate_json` / `orbat_render_json` 增加可选 `dsl` 参数；二选一。
- 或新增 `orbat_render_dsl`，一次完成“编译 → 校验 → 归一化 → 出图”。
- **一次调用完成**，不增加 round-trip；这是 P2 能否省 token 的关键。

建议优先做 `orbat_render_dsl`，`orbat_compile_dsl` 只在需要“先看编译结果”时提供。

## 4. 可行性判断

| 项 | 判断 | 说明 |
|----|------|------|
| 类型 → 实体码 | **高** | 纯查表；需要一份权威码表 |
| 梯队 → 2 位码 | **高** | 规则固定；`19/20` 禁用 |
| 30 位拼接 | **高** | 纯字符串；可 100% 单测 |
| 7 键归一化 | **高** | 已有现成逻辑 |
| 未收录类型 | **中** | 返回候选 + 要求显式 `sidc`，不猜 |
| 陆/空/海符号集 | **中** | DSL 需要 `domain: land/air/sea`，否则航空单位会错 |
| 历史项目约定 | **低** | 美军 BCT/苏军华约的旧码与新站点语义冲突；DSL 不应内置旧约定 |
| 与现有 raw JSON 兼容 | **高** | 保留 `json` 路径，DSL 只是新增入口 |

**最大风险不是技术，而是码表权威性。** 必须明确：类型表以 spatialillusions 站点语义为准，旧项目码只做维护兼容，不进入新 DSL 默认表。

## 5. 可用性评估

**会变好的地方**
- 模型不再背 30 位字符串，减少“少一位/多一位”的低级错误。
- 校验错误可以按 `name` 报，而不是按 `root/subOrganizations/3/options/sidc` 报，修起来更快。
- 类型词表是封闭集合，模型不用每次查 reference。
- 可以把“边防用步兵”这类规则内置：`border_*` 类型直接映射 `121100`。

**可能变差的地方**
- 如果 DSL 字段太多（type/echelon/domain/notes/…），模型写 DSL 的 token 可能接近写 JSON。
- 如果 DSL 编译失败要单独一轮，反而增加 round-trip。
- 类型词表如果太细（几十个兵种 × 级别），模型选类型也会犹豫。
- 旧数据、特殊单位仍需要 raw SIDC 逃生口，否则 DSL 会变成新瓶颈。

**结论：DSL 应保持“窄”——只覆盖 80% 常见陆军单位；特殊单位走 `sidc` 覆盖。**

## 6. 详细落地清单

### 阶段 0：码表与契约（0.5 天）
- [ ] 冻结 `type` 词表 v1：先覆盖 30–40 个常见类型（步兵、装甲、炮兵、防空、航空、工兵、通信、情报、宪兵、勤务、HQ）。
- [ ] 每个类型记录：`id`、中文名、6 位实体码、适用 domain、别名。
- [ ] 明确码表来源与版本（站点码表日期），写进 `reference/sidc-codes.md` 顶部。
- [ ] 定义 DSL schema：`name` / `type` / `echelon` / `sidc?` / `note?` / `children`。
- [ ] 定义错误码：`UNKNOWN_TYPE`、`UNKNOWN_ECHELON`、`MISSING_TYPE`、`CONFLICT_SIDC`。

### 阶段 1：编译器核心（1 天）
- [ ] `lib/sidc_compiler.js`：`compileNode({type,echelon,sidc})`。
- [ ] 梯队表：`15/16/17/18/21/22/23`；显式拒绝 `19/20`。
- [ ] 尾部固定 14 个 0；输出后断言长度 === 30。
- [ ] `compileTree(dsl)`：递归、保留 children 顺序、生成 7 键 options。
- [ ] 单测：每个类型/梯队组合、长度、非法 type、显式 sidc 覆盖、空 children。
- [ ] golden test：用第101空降师 44 节点 DSL 编译，结果与现有 JSON 逐节点等价。

### 阶段 2：工具面（0.5 天）
- [ ] `orbat_render_json` 增加可选 `dsl`（与 `json` 二选一）。
- [ ] 或新增 `orbat_render_dsl`，内部复用现有 `render()`。
- [ ] 编译失败返回 `issues`：`path` 用节点名，`message` 给候选类型。
- [ ] 未知类型时返回最多 5 个模糊匹配候选，不自动猜。
- [ ] 保留 raw `json` 路径，不破坏旧调用。

### 阶段 3：技能与提示（0.5 天）
- [ ] L1 快卡增加“有 DSL 时优先 DSL；特殊单位用 sidc 覆盖”。
- [ ] 类型词表放 `reference/dsl-types.md`，只在 `UNKNOWN_TYPE` 时加载。
- [ ] 明确“不要为了 DSL 去查 SIDC 码表”；编译器负责。

### 阶段 4：验收与度量（0.5 天）
- [ ] 同一张 44 节点图，raw JSON vs DSL 各跑 3 次，记录：输入 token、输出 token、工具轮次、红牌数、修正次数。
- [ ] 验收线：红牌 0；轮次不增加；输入 token 下降 ≥20%；无新增未知图标。
- [ ] 若 token 下降 <10%，停止扩展 DSL，只保留“类型预设”作为可选快捷方式。

## 7. 建议的最终形态

**先做“类型预设 + 自动拼 SIDC”，不要做完整 DSL。**

即：

```json
{
  "name": "第1营",
  "type": "infantry_battalion",
  "echelon": "battalion"
}
```

插件内部补成标准 ORBAT JSON。这样：
- 模型只写 3 个短字段；
- 不需要学 YAML；
- 不需要一次改完整工具协议；
- 失败时还能回退到 raw `sidc`。

等这个版本跑顺、度量证明有效，再决定要不要加 `children` 嵌套 DSL。

## 8. 工作量与优先级

- 阶段 0–2：约 2 天，能拿到 80% 收益。
- 阶段 3–4：约 1 天，主要是技能与度量。
- 风险缓冲：0.5–1 天（码表争议、航空/海军 domain）。
- **建议优先级：P2 低于“重启后验证 workspace 默认落盘”和“P1 技能实测”，高于“完整 DSL”。**
