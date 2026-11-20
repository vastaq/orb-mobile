import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/calendar_tools.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/main.dart';

import 'live_workspace_program_test.dart' show RelayedLiveConfig;
import 'personal_memory_test.dart' show PersonalTestStore;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'a remembered place is used in a system appointment after an explicit preview',
    (tester) async {
      for (final (preset, model, port, title, location) in [
        (
          ModelConfig.deepSeek,
          'deepseek-flash',
          const int.fromEnvironment('ORB_DEEPSEEK_PORT'),
          '纸桥走读',
          '靛蓝木屋',
        ),
        (
          ModelConfig.openAI,
          'gpt-5.4-mini',
          const int.fromEnvironment('ORB_OPENAI_PORT'),
          '松纹走读',
          '竹青木屋',
        ),
      ]) {
        final store = PersonalTestStore(
          RelayedLiveConfig(preset.baseUrl, model, port),
        );
        final orb = OrbController(store: store);
        final threads = <String>{};
        await tester.pumpWidget(OrbApp(key: ValueKey(model), controller: orb));
        Future<void> until(bool Function() done) async {
          final elapsed = Stopwatch()..start();
          while (!done() && elapsed.elapsed < const Duration(minutes: 3)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(done(), isTrue);
        }

        await until(() => orb.ready);
        final wasAuto = orb.autoMemoryEnabled;
        try {
          await orb.setAutoMemoryEnabled(true);
          await orb.newChat();
          await orb.send('请记住，我固定在「$location」办「$title」，以后还会一直在那里办。');
          threads.add(orb.activeId!);
          await until(() => !orb.remembering);
          expect(orb.memories.any((m) => m.text.contains(location)), isTrue);
          await orb.newChat();
          final sending = orb.send(
            '在系统日历 Orb Calendar Lab 里，帮我创建一场「$title」，2032年6月14日 14:00 到 15:00，按 UTC 时间。地点用我以前告诉你的固定活动地点。请直接创建。',
          );
          final confirm = find.widgetWithText(FilledButton, '创建日程');
          await until(() => confirm.evaluate().isNotEmpty || !orb.busy);
          expect(confirm, findsOneWidget);
          final preview = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Text),
          );
          final text = tester
              .widgetList<Text>(preview)
              .map((t) => t.data ?? '')
              .join('\n');
          expect(text, contains('Orb Calendar Lab'));
          expect(text, contains(location));
          expect(text, contains(title));
          await tester.tap(confirm);
          await tester.pump();
          await sending.timeout(const Duration(minutes: 3));
          await until(() => !orb.remembering);
          threads.add(orb.activeId!);
          expect(orb.error, isNull);
          final answer = (await orb.historyFor(orb.activeId!)).last;
          final receipts = (answer.metadata['localTools'] as List)
              .whereType<Map>();
          final created = receipts.singleWhere(
            (r) => r['name'] == 'calendar_create' && r['ok'] == true,
          );
          final record = await CalendarTools.channel
              .invokeMapMethod<dynamic, dynamic>('get', {
                'id': created['id'],
                'calendarId': created['calendar_id'],
              });
          expect(record?['title'], title);
          expect(record?['location'], location);
          expect(
            record?['startMs'],
            DateTime.utc(2032, 6, 14, 14).millisecondsSinceEpoch,
          );
          expect(
            record?['endMs'],
            DateTime.utc(2032, 6, 14, 15).millisecondsSinceEpoch,
          );
          // Leave these two synthetic appointments in the fixture until the
          // independent host Calendar Provider check and fixture cleanup.
          debugPrint('ORB_PERSONAL_CALENDAR_PASS $model ${created['id']}');
        } finally {
          await tester.pumpWidget(const SizedBox());
          for (final m
              in orb.memories
                  .where(
                    (m) => m.text.contains(location) || m.text.contains(title),
                  )
                  .toList()) {
            await orb.removeMemory(m.id);
          }
          await orb.newChat();
          for (final id in threads) {
            await orb.removeChat(id);
          }
          await orb.setAutoMemoryEnabled(wasAuto);
          orb.dispose();
        }
      }
    },
    skip:
        const int.fromEnvironment('ORB_DEEPSEEK_PORT') == 0 ||
        const int.fromEnvironment('ORB_OPENAI_PORT') == 0,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
