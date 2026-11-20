// Run twice on the same dedicated simulator. Stop the application process
// between invocations. The second invocation verifies the first one's data.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:path_provider/path_provider.dart';

import 'live_workspace_program_test.dart' show RelayedLiveConfig;
import 'personal_memory_test.dart' show PersonalTestStore;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'a stored preference survives application process termination',
    (_) async {
      const port = int.fromEnvironment('ORB_DEEPSEEK_PORT');
      final marker = File(
        '${(await getApplicationSupportDirectory()).path}/orb-cold-memory-test.json',
      );
      final orb = OrbController(
        store: PersonalTestStore(
          RelayedLiveConfig(
            ModelConfig.deepSeek.baseUrl,
            'deepseek-flash',
            port,
          ),
        ),
      );
      await orb.initialize();
      expect(orb.ready, isTrue);
      const token = '砾光步道';
      Future<void> settle() async {
        final timer = Stopwatch()..start();
        while (orb.remembering && timer.elapsed < const Duration(minutes: 1)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(orb.remembering, isFalse);
      }

      try {
        if (!await marker.exists()) {
          final auto = orb.autoMemoryEnabled;
          expect(orb.memories.any((m) => m.text.contains(token)), isFalse);
          await orb.setAutoMemoryEnabled(true);
          await orb.newChat();
          await orb.send('请记住，我的木刻练习本一直采用的封面主题叫「$token」。');
          await settle();
          final saved = orb.memories.singleWhere((m) => m.text.contains(token));
          await marker.writeAsString(
            jsonEncode({
              'id': saved.id,
              'thread': orb.activeId,
              'auto': auto,
              'pid': pid,
            }),
            flush: true,
          );
          // ignore: avoid_print
          print('ORB_COLD_MEMORY_STORED pid=$pid');
        } else {
          final record = jsonDecode(await marker.readAsString()) as Map;
          expect(pid, isNot(record['pid']));
          expect(
            orb.memories.singleWhere((m) => m.id == record['id']).text,
            contains(token),
          );
          await orb.newChat();
          await orb.send('我的木刻练习本封面主题叫什么名字？');
          await settle();
          final reply = (await orb.historyFor(orb.activeId!)).last;
          expect(reply.text, contains(token));
          expect(
            (reply.metadata['context'] as Map)['memoryIds'],
            contains(record['id']),
          );
          // ignore: avoid_print
          print(
            'ORB_COLD_MEMORY_RECALLED old_pid=${record['pid']} new_pid=$pid',
          );
          final second = orb.activeId!;
          await orb.newChat();
          await orb.removeChat(second);
          await orb.removeChat(record['thread'] as String);
          await orb.removeMemory(record['id'] as String);
          await orb.setAutoMemoryEnabled(record['auto'] as bool);
          await marker.delete();
        }
      } finally {
        orb.dispose();
      }
    },
    skip:
        !const bool.fromEnvironment('ORB_COLD_MEMORY') ||
        const int.fromEnvironment('ORB_DEEPSEEK_PORT') == 0,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
