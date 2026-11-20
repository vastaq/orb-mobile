import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/ui/history.dart';

void main() {
  testWidgets('date groups and search retain the selected conversation id', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    final controller = OrbController()
      ..threads = [
        OrbThread('book', '读书清单', updatedAt: today),
        OrbThread(
          'walk',
          '上次散步',
          updatedAt: today.subtract(const Duration(days: 1)),
        ),
        const OrbThread('legacy', '旧对话'),
      ];
    String? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          drawer: HistoryDrawer(
            controller: controller,
            onSelect: (id) async {
              selection = id;
            },
          ),
          body: const SizedBox(),
        ),
      ),
    );
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    for (final label in ['今天', '昨天', '更早', '读书清单', '设置']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('定时任务'), findsNothing);
    await tester.tap(find.byTooltip('搜索对话'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '散步');
    await tester.pump();
    expect(find.text('读书清单'), findsNothing);
    await tester.tap(find.text('上次散步'));
    await tester.pumpAndSettle();
    expect(selection, 'walk');
  });
}
