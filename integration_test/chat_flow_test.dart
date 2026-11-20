import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/main.dart';

const _url = String.fromEnvironment('ORB_TEST_BASE_URL');
const _model = String.fromEnvironment('ORB_TEST_MODEL');
const _screenshots = bool.fromEnvironment('ORB_TEST_SCREENSHOTS');
const _before = '我给正在写的曲子暂定名叫《初稿》。';
const _memory = '我给正在写的曲子定名叫《晚风来信》。';
const _question = '我给正在写的那首曲子起了什么名字？只告诉我曲名。';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'configure a model, edit memory, send, open history, and reopen local data',
    (tester) async {
      Future<void> waitFor(bool Function() check, String description) async {
        final timer = Stopwatch()..start();
        while (!check() && timer.elapsed < const Duration(seconds: 60)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(check(), isTrue, reason: description);
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> typeInto(Finder field, String value) async {
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pump(const Duration(milliseconds: 320));
        await tester.showKeyboard(field);
        await tester.enterText(field, value);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller?.text, value);
      }

      Future<void> capture(String name) async {
        if (!_screenshots) return;
        final bytes = await binding.takeScreenshot(name);
        await File('${Directory.systemTemp.path}/orb-uat-$name.png')
            .writeAsBytes(bytes);
      }

      final orb = OrbController();
      await tester.pumpWidget(OrbApp(controller: orb));
      await waitFor(
        () => orb.ready || orb.error != null,
        'local storage initialization',
      );
      expect(orb.error, isNull);
      // Reruns remove only the last run's named fixtures on this test device.
      for (final memory in [...orb.memories]) {
        if (memory.text == _before || memory.text == _memory) {
          await orb.removeMemory(memory.id);
        }
      }
      for (final thread in [...orb.threads]) {
        if (thread.title == _question) await orb.removeChat(thread.id);
      }
      await tester.pump();
      final initialPrompts = orb.prompts;
      final promptName = '短句助手';
      final templateName = '验收提问';
      const templateBody = '请用短句告诉我曲名。';
      Finder field(String name) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == name,
      );
      await tap(find.byTooltip('对话与设置'));
      await tap(find.text('设置'));
      await tap(find.text('个人指令与模板'));
      await typeInto(field('助手名称'), promptName);
      await typeInto(field('个人指令'), '请用简短中文回复。');
      await tap(find.byTooltip('添加模板'));
      await typeInto(field('模板名称'), templateName);
      await typeInto(field('模板内容'), templateBody);
      await waitFor(
        () =>
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, '完成'))
                .onPressed !=
            null,
        '模板内容可保存',
      );
      await tap(find.text('完成'));
      await waitFor(
        () =>
            find.text(templateName).evaluate().isNotEmpty &&
            find.text('完成').evaluate().isEmpty,
        '模板编辑器已关闭',
      );
      await capture('prompt-settings');
      await tap(find.text('保存'));
      await waitFor(
        () =>
            orb.prompts.displayName == promptName &&
            find.text('个人指令与模板').evaluate().isNotEmpty,
        '提示已保存并返回设置',
      );
      await tap(find.byType(BackButton));
      expect(find.text(promptName), findsOneWidget);
      await tap(find.byTooltip('添加工具或附件'));
      await tap(find.text('更多输入'));
      await tap(find.text('提示模板'));
      await tap(find.text(templateName));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('composer')))
            .controller!
            .text,
        templateBody,
      );
      await typeInto(find.byKey(const ValueKey('composer')), '');
      await tester.pumpAndSettle();
      await tap(find.byTooltip('模型连接'));
      await tap(find.text('兼容接口'));
      await typeInto(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '服务地址',
        ),
        _url,
      );
      await typeInto(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '模型 ID',
        ),
        _model,
      );
      await tap(find.text('保存'));
      expect(orb.config.model, _model);
      expect(orb.config.baseUrl, _url);

      await tap(find.byTooltip('对话与设置'));
      await tap(find.text('设置'));
      await tap(find.text('本地记忆'));
      await tap(find.byTooltip('添加记忆'));
      await typeInto(find.byType(TextField), _before);
      await tap(find.text('保存'));
      await tap(find.text(_before));
      await typeInto(find.byType(TextField), _memory);
      await tap(find.text('保存'));
      expect(find.text(_before), findsNothing);
      expect(find.text(_memory), findsOneWidget);
      await capture('memory');
      await tap(find.byType(BackButton));
      await tap(find.byType(BackButton));

      await tap(find.byTooltip('新对话'));
      await waitFor(
        () => orb.activeId == null && orb.messages.isEmpty,
        '新对话准备就绪',
      );
      await tester.pump(const Duration(milliseconds: 100));
      final composer = find.byKey(const ValueKey('composer'));
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 320));
      await tester.showKeyboard(composer);
      await typeInto(composer, _question);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('send')));
      expect(
        tester.widget<IconButton>(find.byKey(const ValueKey('send'))).onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('send')));
      await waitFor(
        () =>
            orb.messages.any((e) => e.role == 'assistant') && !orb.busy ||
            orb.error != null,
        'real model response and completion',
      );
      expect(orb.error, isNull);
      expect(orb.messages.length, 2);
      expect(orb.messages.last.text, contains('晚风来信'));
      final thread = orb.activeId!;
      final reply = orb.messages.last.text;
      await tester.pumpAndSettle();
      await capture('reply');

      await tap(find.byTooltip('新对话'));
      await waitFor(
        () => orb.activeId == null && orb.messages.isEmpty,
        '已切换到新对话',
      );
      await tap(find.byTooltip('对话与设置'));
      expect(find.text(_question), findsOneWidget);
      await capture('history');
      await tap(find.text(_question));
      await waitFor(() => orb.activeId == thread, '已选择历史对话');
      expect(orb.messages.last.text, reply);

      // Cold Dart state verifies persistence through SQLite and platform secure storage.
      await tester.pumpWidget(const SizedBox());
      orb.dispose();
      final restored = OrbController();
      await tester.pumpWidget(OrbApp(controller: restored));
      await waitFor(
        () => restored.ready || restored.error != null,
        'reopen local storage',
      );
      expect(restored.error, isNull);
      expect(restored.config.baseUrl, _url);
      expect(restored.config.model, _model);
      expect(restored.activeId, thread);
      expect(restored.messages.last.text, reply);
      expect(restored.memories.map((m) => m.text), contains(_memory));
      expect(restored.memories.map((m) => m.text), isNot(contains(_before)));
      await tester.pumpAndSettle();
      await capture('reopened');
      expect(restored.prompts.displayName, promptName);
      expect(
        restored.prompts.templates.any((t) => t.text == templateBody),
        isTrue,
      );
      await restored.savePrompts(initialPrompts);
    },
    skip: _url.isEmpty || _model.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
