import 'package:flutter/material.dart';

import '../core/orbat.dart';
import '../core/sidc.dart';
import '../core/sidc_tables.dart';

/// 编制树可视化 —— 每个节点展示名称、SIDC 解读与校验状态
class TreeView extends StatefulWidget {
  final OrbatNode root;
  final ValidationReport? report;

  /// 外部指定要聚焦的节点路径（来自校验问题列表点击）。
  /// 变化时自动展开祖先并滚动到该节点。
  final String? focusPath;

  const TreeView({
    super.key,
    required this.root,
    this.report,
    this.focusPath,
  });

  @override
  State<TreeView> createState() => _TreeViewState();
}

class _TreeViewState extends State<TreeView> {
  /// 已折叠节点的路径集合
  final Set<String> _collapsed = <String>{};
  String? _selectedPath;

  /// 把校验问题按路径索引，便于节点上打标
  Map<String, List<ValidationIssue>> get _issuesByPath {
    final map = <String, List<ValidationIssue>>{};
    for (final i in widget.report?.issues ?? const <ValidationIssue>[]) {
      map.putIfAbsent(i.path, () => []).add(i);
    }
    return map;
  }

  @override
  void didUpdateWidget(covariant TreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusPath != null && widget.focusPath != oldWidget.focusPath) {
      final p = widget.focusPath!;
      setState(() {
        _selectedPath = p;
        // 展开所有祖先，确保目标节点可见
        final parts = p.split('/');
        var prefix = '';
        for (final seg in parts.take(parts.length - 1)) {
          prefix = prefix.isEmpty ? seg : '$prefix/$seg';
          _collapsed.remove(prefix);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final issues = _issuesByPath;
    final rows = <Widget>[];
    _buildRows(context, widget.root, '根', 0, issues, rows);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      children: rows,
    );
  }

  void _buildRows(
    BuildContext context,
    OrbatNode node,
    String path,
    int depth,
    Map<String, List<ValidationIssue>> issues,
    List<Widget> out,
  ) {
    final theme = Theme.of(context);
    final nodeIssues = issues[path] ?? const <ValidationIssue>[];
    final reds = nodeIssues.where((i) => i.level == 'red').length;
    final warns = nodeIssues.where((i) => i.level == 'warn').length;

    final collapsed = _collapsed.contains(path);
    final hasChildren = node.children.isNotEmpty;
    final selected = _selectedPath == path;

    // 层级色带
    final depthColor = _depthColor(depth);

    out.add(
      Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        child: InkWell(
          onTap: () => setState(
              () => _selectedPath = selected ? null : path),
          child: Padding(
            padding: EdgeInsets.only(
              left: 8.0 + depth * 18,
              top: 6,
              bottom: 6,
              right: 8,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 展开箭头 / 占位
                SizedBox(
                  width: 20,
                  child: hasChildren
                      ? InkWell(
                          onTap: () => setState(() {
                            if (collapsed) {
                              _collapsed.remove(path);
                            } else {
                              _collapsed.add(path);
                            }
                          }),
                          child: Icon(
                            collapsed
                                ? Icons.chevron_right
                                : Icons.keyboard_arrow_down,
                            size: 18,
                            color: theme.hintColor,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                // 层级色带
                Container(
                  width: 3,
                  height: 30,
                  margin: const EdgeInsets.only(right: 10, top: 1),
                  decoration: BoxDecoration(
                    color: depthColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 内容
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              node.uniqueDesignation.isEmpty
                                  ? '(无名)'
                                  : node.uniqueDesignation,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: depth <= 1
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (reds > 0)
                            _badge('红牌 $reds', Colors.red)
                          else if (warns > 0)
                            _badge('警告 $warns', Colors.orange),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _describeSidc(node.sidc),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.hintColor,
                          fontFamily: 'Consolas',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (hasChildren)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 3),
                    child: Text(
                      '${node.children.length}',
                      style: TextStyle(fontSize: 11, color: theme.hintColor),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // 选中时展开详情
    if (selected) {
      out.add(_detailCard(context, node, nodeIssues, depth));
    }

    if (!collapsed) {
      for (final child in node.children) {
        _buildRows(context, child, '$path/${child.uniqueDesignation}', depth + 1,
            issues, out);
      }
    }
  }

  Widget _badge(String text, MaterialColor color) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color.shade300)),
    );
  }

  Widget _detailCard(BuildContext context, OrbatNode node,
      List<ValidationIssue> issues, int depth) {
    final theme = Theme.of(context);
    final sidc = Sidc.parse(node.sidc);
    return Container(
      margin: EdgeInsets.only(left: 40.0 + depth * 18, right: 12, top: 2, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('SIDC', node.sidc, mono: true),
          if (sidc != null) ...[
            const SizedBox(height: 6),
            _kv('符号集', sidc.symbolSet == '01' ? '空中 (01)' : '陆地 (10)'),
            _kv('梯队', '${kEchelon[sidc.echelon] ?? sidc.echelon} (${sidc.echelon})'),
            _kv('主实体', '${sidc.entityName} (${sidc.entity})'),
            _kv('类型修饰', '${kTypeModifier[sidc.typeMod] ?? "未知"} (${sidc.typeMod})'),
            _kv('机动修饰',
                '${kMobilityModifier[sidc.mobilityMod] ?? "未知"} (${sidc.mobilityMod})'),
            _kv('扇区修饰',
                '${kSectorModifier[sidc.sectorMod] ?? "未知"} (${sidc.sectorMod})'),
          ],
          if (node.additionalInformation.isNotEmpty) ...[
            const SizedBox(height: 6),
            _kv('注释', node.additionalInformation),
          ],
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...issues.map((i) => Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${i.level == 'red' ? '●' : '○'} ${i.message}',
                    style: TextStyle(
                      fontSize: 11,
                      color: i.level == 'red' ? Colors.redAccent : Colors.orange,
                    ),
                  ),
                )),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(k, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: TextStyle(
                fontSize: 11,
                fontFamily: mono ? 'Consolas' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 不抛异常的 SIDC 解读
  String _describeSidc(String code) {
    final s = Sidc.parse(code);
    if (s == null) return 'SIDC 非法（${code.length} 位）: $code';
    return '${s.symbolSet == '01' ? '空' : '陆'} · '
        '${kEchelon[s.echelon] ?? s.echelon} · ${s.entityName}';
  }

  Color _depthColor(int depth) {
    const palette = [
      Color(0xFF2E6BE6),
      Color(0xFF00A6A6),
      Color(0xFF8E6BE6),
      Color(0xFFD98E04),
      Color(0xFF8D8D8D),
    ];
    return palette[depth.clamp(0, palette.length - 1)];
  }
}
