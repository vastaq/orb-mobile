import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/orb_store.dart';

import 'live_workspace_program_test.dart' show RelayedLiveConfig;

// Only the provider and credential source change. Preferences, extraction,
// retrieval, turn receipts and editing use Orb's real device database.
class PersonalTestStore extends OrbStore {
  PersonalTestStore(this.config);
  final ModelConfig config;
  @override
  Future<ModelConfig> loadConfig() async => config;
  @override
  Future<Map<String, ModelConfig>> loadProfiles() async => {};
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'both providers remember, recall, correct and forget across fresh chats',
    (tester) async {
      for (final (preset, model, port, before, after) in [
        (
          ModelConfig.deepSeek,
          'deepseek-flash',
          const int.fromEnvironment('ORB_DEEPSEEK_PORT'),
          '柠黄河岸',
          '雾青渡口',
        ),
        (
          ModelConfig.openAI,
          'gpt-5.4-mini',
          const int.fromEnvironment('ORB_OPENAI_PORT'),
          '松蓝灯塔',
          '暖橙浮岛',
        ),
      ]) {
        expect(port, greaterThan(0));
        final config = RelayedLiveConfig(preset.baseUrl, model, port);
        OrbController controller() =>
            OrbController(store: PersonalTestStore(config));
        var orb = controller();
        final threads = <String>{};
        final topic = '手作周刊';
        bool matches(OrbMemory m) =>
            m.text.contains(before) || m.text.contains(after);
        Future<OrbMessage> turn(String prompt) async {
          await orb.newChat();
          await orb.send(prompt).timeout(const Duration(minutes: 3));
          expect(orb.error, isNull);
          threads.add(orb.activeId!);
          final timer = Stopwatch()..start();
          while (orb.remembering &&
              timer.elapsed < const Duration(seconds: 60)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(orb.remembering, isFalse);
          return (await orb.historyFor(orb.activeId!)).last;
        }

        await orb.initialize();
        expect(
          orb.memories.where(matches),
          isEmpty,
          reason: 'Use a clean, dedicated emulator.',
        );
        final wasAuto = orb.autoMemoryEnabled;
        try {
          await orb.setAutoMemoryEnabled(true);
          await turn('请记住，我的$topic封面配色方案叫「$before」，以后一直沿用。');
          final saved = orb.memories.singleWhere(matches);
          expect(saved.text, contains(before));

          orb.dispose();
          orb = controller();
          await orb.initialize();
          expect(orb.memories.singleWhere(matches).id, saved.id);
          final recall = await turn('我的$topic封面平时用的方案叫什么？');
          expect(recall.text, contains(before));
          expect(
            (recall.metadata['context'] as Map)['memoryIds'],
            contains(saved.id),
          );

          await turn('纠正一下，我的$topic封面配色方案已经改成「$after」，原来的方案作废，请更新记忆。');
          expect(orb.memories.where(matches), hasLength(1));
          expect(orb.memories.singleWhere(matches).text, contains(after));
          final corrected = await turn('我现在的$topic封面配色方案叫什么？仅说现在的名称。');
          expect(corrected.text, contains(after));
          expect(corrected.text, isNot(contains(before)));

          await turn('请忘掉我的$topic封面配色方案，把那条记忆删掉。');
          expect(orb.memories.where(matches), isEmpty);
          final forgotten = await turn(
            '我之前告诉过你的$topic封面配色方案叫什么？如果无法知道就直接说不知道。',
          );
          expect(forgotten.text, isNot(contains(before)));
          expect(forgotten.text, isNot(contains(after)));
          expect(
            (forgotten.metadata['context'] as Map)['memoryIds'],
            isNot(contains(saved.id)),
          );
          // Synthetic example only. Verify that the sensitive-input guard also
          // applies when the user explicitly asks to persist a credential.
          await turn('请记住演示用的假密码是假-桃花-111。');
          expect(orb.memories.any((m) => m.text.contains('桃花')), isFalse);
          // ignore: avoid_print
          print(
            'ORB_MEMORY_PASS $model stored=reloaded recalled corrected forgotten synthetic-secret-skipped',
          );
        } finally {
          for (final m in orb.memories.where(matches).toList()) {
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
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
