import 'package:flutter/material.dart';

import '../core/token_usage.dart';

class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key});
  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  static const outputColor = Color(0xffa7b5a2);
  int days = 7;
  late Future<List<Map<String, Object?>>> rows;
  DateTime date(int back) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day - back);
  }

  void refresh() => rows = UsageLog.since(date(days - 1));
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Widget group(Map<String, int> values) {
    final items = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      children: [
        for (final e in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                Expanded(child: Text(e.key)),
                Text(formatTokens(e.value)),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('模型用量'),
      actions: [
        PopupMenuButton<String>(
          onSelected: (_) async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('清除本机用量记录？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('清除'),
                  ),
                ],
              ),
            );
            if (ok == true) {
              await UsageLog.clear();
              if (mounted) setState(refresh);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'clear', child: Text('清除用量记录')),
          ],
        ),
      ],
    ),
    body: SafeArea(
      child: FutureBuilder(
        future: rows,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(refresh),
                child: const Text('无法读取用量，重试'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snapshot.requireData,
              models = <String, int>{},
              purposes = <String, int>{},
              bars = List.generate(days, (_) => [0, 0]);
          var input = 0, output = 0, cached = 0, missing = 0;
          for (final r in list) {
            if (r['input'] == null || r['output'] == null) {
              missing++;
              continue;
            }
            final a = r['input'] as int, b = r['output'] as int;
            input += a;
            output += b;
            cached += r['cached'] as int? ?? 0;
            final when = DateTime.fromMillisecondsSinceEpoch(r['at'] as int);
            final offset = DateTime.utc(
              when.year,
              when.month,
              when.day,
            ).difference(date(days - 1).toUtcDay()).inDays;
            if (offset >= 0 && offset < days) {
              bars[offset][0] += a;
              bars[offset][1] += b;
            }
            for (final (map, key) in [
              (models, 'model'),
              (purposes, 'purpose'),
            ]) {
              map.update(
                r[key] as String,
                (v) => v + a + b,
                ifAbsent: () => a + b,
              );
            }
          }
          final max = bars.fold(1, (v, b) => v > b[0] + b[1] ? v : b[0] + b[1]);
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 7, label: Text('近 7 天')),
                    ButtonSegment(value: 30, label: Text('近 30 天')),
                  ],
                  selected: {days},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() {
                    days = v.first;
                    refresh();
                  }),
                ),
              ),
              const SizedBox(height: 26),
              const Text('已回报的 token', style: TextStyle(color: Colors.grey)),
              Text(
                formatTokens(input + output),
                style: const TextStyle(
                  fontSize: 46,
                  letterSpacing: -2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 102,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final (index, b) in bars.indexed)
                      Expanded(
                        child: Tooltip(
                          message:
                              '${date(days - 1 - index).month}/${date(days - 1 - index).day} · 输入 ${b[0]} · 输出 ${b[1]}',
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: days == 7 ? 5 : 1,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (b[1] > 0)
                                  Container(
                                    height: 96 * b[1] / max,
                                    color: outputColor,
                                  ),
                                Container(
                                  height: b[0] + b[1] == 0
                                      ? 1
                                      : 96 * b[0] / max,
                                  color: b[0] + b[1] == 0
                                      ? const Color(0xff41433d)
                                      : Colors.white,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${date(days - 1).month}/${date(days - 1).day}'),
                  const Text('今天'),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                children: [
                  Text('● 输入 ${formatTokens(input)}'),
                  Text(
                    '● 输出 ${formatTokens(output)}',
                    style: const TextStyle(color: outputColor),
                  ),
                ],
              ),
              if (cached > 0)
                Text(
                  '其中缓存命中 ${formatTokens(cached)}',
                  style: const TextStyle(color: Colors.grey),
                ),
              const Divider(height: 40),
              if (list.isEmpty)
                const Text('这段时间还没有模型请求。')
              else ...[
                const Text(
                  '按模型',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                group(models),
                const SizedBox(height: 18),
                const Text(
                  '按用途',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                group(purposes),
              ],
              const SizedBox(height: 20),
              Text(
                '记录 ${list.length} 次文本模型请求，其中 $missing 次未回报完整用量。语音和独立工具另按供应商规则计费。',
                style: const TextStyle(color: Colors.grey, height: 1.5),
              ),
            ],
          );
        },
      ),
    ),
  );
}

extension on DateTime {
  DateTime toUtcDay() => DateTime.utc(year, month, day);
}

String formatTokens(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
