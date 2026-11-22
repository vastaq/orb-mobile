import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/mcp_client.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/main.dart';

import 'live_workspace_program_test.dart' show RelayedLiveConfig, LiveTestStore;

// Start tool/product_benchmark/notes_service.py on the host and adb reverse its
// port. The state oracle reads the notebook independently of Orb and the model.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'remote note changes only after the user confirms the model action',
    (tester) async {
      const port = int.fromEnvironment('ORB_NOTES_PORT');
      const apiPort = int.fromEnvironment('ORB_DEEPSEEK_PORT');
      final uri = Uri.parse('http://127.0.0.1:$port');
      final http = HttpClient();
      Future<Map> state() async {
        final res = await (await http.getUrl(uri.resolve('/state'))).close();
        return jsonDecode(await utf8.decoder.bind(res).join()) as Map;
      }

      final store = await McpConnections.open();
      final c = await store.add('外部测试笔记本', uri.resolve('/mcp').toString(), '');
      final orb = OrbController(
        store: LiveTestStore(
          RelayedLiveConfig(
            ModelConfig.deepSeek.baseUrl,
            'deepseek-flash',
            apiPort,
          ),
        ),
      );
      final threads = <String>{};
      Future<void> until(bool Function() done) async {
        final timer = Stopwatch()..start();
        while (!done() && timer.elapsed < const Duration(minutes: 3)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(done(), isTrue);
      }

      try {
        store.allow(c.id, 'read_note', true);
        store.allow(c.id, 'replace_note', true, permitWrites: true);
        await tester.pumpWidget(OrbApp(controller: orb));
        await until(() => orb.ready);
        final initial = await state();
        expect(initial['writes'], 0);
        const newText = '资料架是青色。';
        for (final approve in [false, true]) {
          await orb.newChat();
          final sending = orb.send('请使用外部测试笔记本的工具，把该笔记本的整页内容准确替换为「$newText」。');
          final dialog = find.byType(AlertDialog);
          await until(() => dialog.evaluate().isNotEmpty || !orb.busy);
          expect(dialog, findsOneWidget);
          expect(
            find.descendant(of: dialog, matching: find.textContaining(newText)),
            findsOneWidget,
          );
          expect(await state(), initial);
          if (!approve && const bool.fromEnvironment('ORB_SCREENSHOTS')) {
            // Allow the host to capture this actual system viewport while the
            // assistant is waiting for the user. The chat spinner is animated.
            await tester.pump(const Duration(milliseconds: 350));
            debugPrint('ORB_CAPTURE_NOTE_CONFIRMATION');
            await Future<void>.delayed(const Duration(seconds: 4));
          }
          await tester.tap(
            find.widgetWithText(
              approve ? FilledButton : TextButton,
              approve ? '允许这次操作' : '取消',
            ),
          );
          await tester.pump();
          await sending.timeout(const Duration(minutes: 2));
          threads.add(orb.activeId!);
          expect(
            await state(),
            approve ? {'text': newText, 'writes': 1} : initial,
          );
        }
        store.allow(c.id, 'replace_note', false);
        expect(
          store
              .toolsForTurn(interactive: true)
              .any((t) => t.name.contains('replace_note')),
          isFalse,
        );
        debugPrint('ORB_EXTERNAL_NOTE_PASS denied=0 approved=1 revoked=true');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await store.remove(c.id);
        await orb.newChat();
        for (final id in threads) {
          await orb.removeChat(id);
        }
        orb.dispose();
        http.close(force: true);
      }
    },
    skip:
        const int.fromEnvironment('ORB_NOTES_PORT') == 0 ||
        const int.fromEnvironment('ORB_DEEPSEEK_PORT') == 0,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
