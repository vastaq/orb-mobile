import 'package:flutter/material.dart';

import '../core/orb_controller.dart';
import 'history_transfer.dart';

import 'dart:math' as math;

import 'settings_home.dart';
import 'orb_mark.dart';
import 'tasks.dart';

class HistoryDrawer extends StatefulWidget {
  const HistoryDrawer({
    super.key,
    required this.controller,
    required this.onSelect,
  });
  final OrbController controller;
  final Future<void> Function(String?) onSelect;
  @override
  State<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<HistoryDrawer> {
  String query = '';
  bool searching = false;
  OrbController get orb => widget.controller;
  Future<void> action(String key, OrbThread t) async {
    if (key == 'share') {
      final history = await orb.historyFor(t.id);
      if (mounted) await shareThreadMarkdown(context, t.title, history);
      return;
    }
    final rename = key == 'rename';
    var title = t.title;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(rename ? '重命名对话' : '删除这段对话？'),
        content: rename
            ? TextFormField(
                initialValue: title,
                maxLength: 120,
                autofocus: true,
                onChanged: (v) => title = v,
                onFieldSubmitted: (_) => Navigator.pop(ctx, true),
              )
            : Text(t.title, maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(rename ? '保存' : '删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (rename) {
        await orb.renameThread(t.id, title);
      } else {
        await orb.removeChat(t.id);
      }
    }
  }

  String section(OrbThread t) {
    final now = DateTime.now(), touched = t.updatedAt;
    if (touched == null) return '更早';
    final age = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime.utc(touched.year, touched.month, touched.day)).inDays;
    return age <= 0
        ? '今天'
        : age == 1
        ? '昨天'
        : age < 7
        ? '过去 7 天'
        : '更早';
  }

  @override
  Widget build(BuildContext context) {
    final nav = Navigator.of(context), page = Scaffold.of(context).context;
    final groups = <String, List<OrbThread>>{};
    for (final t in orb.threads.where(
      (t) => t.title.toLowerCase().contains(query.trim().toLowerCase()),
    )) {
      (groups[section(t)] ??= []).add(t);
    }
    void create() {
      nav.pop();
      widget.onSelect(null);
    }

    Widget footer(Glyph icon, String title, VoidCallback action) => InkWell(
      onTap: action,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 24),
            OrbGlyph(icon, size: 20, color: const Color(0xffc0c1b8)),
            const SizedBox(width: 19),
            Text(
              title,
              style: const TextStyle(
                fontFamily: 'OrbSans',
                letterSpacing: 0,
                fontSize: 15,
                color: Color(0xffd7d8cd),
              ),
            ),
          ],
        ),
      ),
    );
    return Drawer(
      width: math.min(328.0, MediaQuery.sizeOf(context).width - 36),
      elevation: 0,
      backgroundColor: const Color(0xff181917),
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 72,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    const SizedBox.square(
                      dimension: 36,
                      child: Center(child: OrbMark(size: 32)),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        orb.prompts.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'OrbInter',
                          fontFamilyFallback: ['OrbSans'],
                          fontSize: 25,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                          color: Color(0xffeeece5),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: searching ? '关闭搜索' : '搜索对话',
                      onPressed: () {
                        setState(() {
                          searching = !searching;
                          if (!searching) query = '';
                        });
                      },
                      icon: searching
                          ? const Icon(Icons.close, size: 22)
                          : Transform.translate(
                              offset: const Offset(1.5, -.5),
                              child: const OrbGlyph(
                                Glyph.search,
                                size: 21,
                                color: Color(0xffc0c1b8),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
              child: searching
                  ? TextField(
                      autofocus: true,
                      onChanged: (v) => setState(() => query = v),
                      decoration: InputDecoration(
                        hintText: '搜索对话标题',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        filled: true,
                        fillColor: const Color(0xff292b26),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(15),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    )
                  : FilledButton(
                      onPressed: orb.busy ? null : create,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xffdaded2),
                        foregroundColor: const Color(0xff20221e),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Row(
                        children: [
                          OrbGlyph(
                            Glyph.add,
                            size: 22,
                            color: Color(0xff20221e),
                          ),
                          SizedBox(width: 10),
                          Text(
                            '新对话',
                            style: TextStyle(
                              fontFamily: 'OrbSans',
                              letterSpacing: 0,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                children: [
                  if (groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                      child: Text(
                        query.isEmpty ? '还没有对话' : '没有找到对话',
                        style: const TextStyle(
                          color: Color(0xffa5a69c),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  for (final g in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 9, 12, 6),
                      child: Text(
                        g.key,
                        style: const TextStyle(
                          fontFamily: 'OrbSans',
                          letterSpacing: 0,
                          fontSize: 12,
                          height: 22 / 12,
                          color: Color(0xffa5a69c),
                        ),
                      ),
                    ),
                    for (final t in g.value)
                      Material(
                        color: t.id == orb.activeId
                            ? const Color(0xff2c2f28)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: orb.busy
                              ? null
                              : () {
                                  nav.pop();
                                  widget.onSelect(t.id);
                                },
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 52),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 5,
                                      ),
                                      child: Text(
                                        t.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'OrbSans',
                                          letterSpacing: 0,
                                          fontSize: 15,
                                          height: 1.45,
                                          color: Color(0xffe2e2d9),
                                        ),
                                      ),
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    tooltip: '对话操作',
                                    enabled: !orb.busy,
                                    onSelected: (s) => action(s, t),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'rename',
                                        child: Text('重命名'),
                                      ),
                                      PopupMenuItem(
                                        value: 'share',
                                        child: Text('导出 Markdown'),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text('删除'),
                                      ),
                                    ],
                                    icon: Transform.translate(
                                      offset: const Offset(-2, -1),
                                      child: const OrbGlyph(
                                        Glyph.more,
                                        size: 20,
                                        color: Color(0xff85877e),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 22),
              child: Divider(height: 1, color: Color(0xff343630)),
            ),
            const SizedBox(height: 7),
            footer(Glyph.clock, '定时任务', () {
              nav.pop();
              openOrbTasks(page, orb);
            }),
            footer(Glyph.settings, '设置', () {
              nav.pop();
              openOrbSettings(page, orb);
            }),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }
}
