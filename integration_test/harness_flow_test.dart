import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/orb_store.dart';
import 'package:orb_mobile/tasks/task_store.dart';
import 'package:orb_mobile/core/workspace.dart';
import 'package:orb_mobile/main.dart';
import 'package:orb_mobile/tasks/task_service.dart';

const _url = String.fromEnvironment('ORB_TEST_BASE_URL');
const _model = String.fromEnvironment('ORB_TEST_MODEL');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'ordinary messages schedule a reminder and maintain a workspace note',
    (tester) async {
      final store = OrbStore();
      final orb = OrbController(store: store);
      await tester.pumpWidget(OrbApp(controller: orb));
      Future<void> wait(bool Function() done) async {
        final elapsed = Stopwatch()..start();
        while (!done() && elapsed.elapsed < const Duration(seconds: 120)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          done(),
          isTrue,
          reason: 'Timed out waiting for Orb. Error: ${orb.error}',
        );
      }

      await wait(() => orb.ready);
      // Passing an inspectable controller bypasses OrbApp.start’s OS hook.
      await initializeOrbTasks(onOpen: (_) {});
      final tasks = await TaskService.open();
      final workspace = await Workspace.open();
      final initialModel = orb.config;
      final memoryWasOn = orb.autoMemoryEnabled;
      final active = orb.activeId;
      final suffix = DateTime.now().microsecondsSinceEpoch.toString().substring(
        9,
      );
      final title = '春灯$suffix';
      final path = '读书/$title.md';
      String? fixtureThread;
      String? taskThread;
      try {
        await orb.setAutoMemoryEnabled(false);
        await orb.saveConfig(
          ModelConfig(baseUrl: _url, model: _model, apiKey: ''),
        );
        await orb.newChat();

        Future<void> say(String request) async {
          final box = find.byKey(const ValueKey('composer'));
          await tester.tap(box);
          await tester.pump(const Duration(milliseconds: 250));
          await tester.showKeyboard(box);
          await tester.enterText(box, request);
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('send')));
          await tester.pump();
          await wait(
            () => !orb.busy && orb.messages.lastOrNull?.role == 'assistant',
          );
          fixtureThread = orb.activeId;
          expect(orb.error, isNull, reason: 'request: $request');
          final answer = orb.messages.last;
          // All messages here belong to the isolated test thread.
          debugPrint(
            'HARNESS E2E: $request => ${answer.text} ${answer.metadata['localTools']}',
          );
          expect(answer.status, 'complete', reason: answer.text);
        }

        final now = DateTime.now();
        final tomorrow = DateTime(now.year, now.month, now.day + 1);
        await say('明天晚上八点提醒我整理《$title》的读书笔记。');
        final matching = (await tasks.store.all())
            .where((t) => t.title.contains(title) || t.body.contains(title))
            .toList();
        expect(matching, hasLength(1), reason: orb.messages.last.text);
        final first = matching.single;
        expect(first.enabled, isTrue);
        expect(
          first.due,
          DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 20),
        );
        await say('把刚才这个提醒改到明天晚上九点，内容不变。');
        final updated = await tasks.store.find(first.id);
        expect(
          updated?.due,
          DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 21),
          reason: orb.messages.last.text,
        );
        expect(updated?.body, first.body);
        await say('在我的工作区文件 $path 里写入一句「想读海边来信」，只写这句话。');
        expect(
          (await workspace.read(path))?.text.trim(),
          '想读海边来信',
          reason: orb.messages.last.text,
        );
        await say('把 $path 中的「海边」改成「山间」，保留其余文字。');
        expect(
          (await workspace.read(path))?.text.trim(),
          '想读山间来信',
          reason: orb.messages.last.text,
        );
        final background = await tasks.save(
          OrbTask(
            title: '$title 工作文件验收',
            body: '请读取工作区文件 $path，回复其中的原文。',
            kind: TaskKind.prompt,
            frequency: TaskFrequency.once,
            due: DateTime.now().add(const Duration(seconds: 10)),
          ),
        );
        // iOS chooses when to grant discretionary background time. Exercise the
        // same public “run now” action as the task details page on that platform.
        // Android waits for the scheduled OS worker, including its cold isolate.
        if (Platform.isIOS) await tasks.runNow(background);
        final elapsed = Stopwatch()..start();
        TaskRun? delivery;
        while (elapsed.elapsed < const Duration(seconds: 100)) {
          final runs = await tasks.store.runs(background.id);
          delivery = runs.firstOrNull;
          if (delivery != null && delivery.status != 'running') break;
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          delivery?.status,
          'done',
          reason: 'System scheduled prompt failed: ${delivery?.result}',
        );
        expect(delivery!.result, contains('想读山间来信'));
        taskThread = delivery.threadId;
        final report = (await orb.historyFor(taskThread!)).last;
        final receipts = report.metadata['localTools'] as List;
        expect(
          receipts.any((r) => r['name'] == 'workspace_read'),
          isTrue,
          reason: '$receipts',
        );
        expect(
          receipts.any((r) => r['name'].toString().startsWith('schedule_')),
          isFalse,
        );
        debugPrint(
          'HARNESS E2E scheduled result: ${delivery.result}, tool receipts: $receipts',
        );
      } finally {
        if (taskThread != null) await orb.removeChat(taskThread);
        for (final t in (await tasks.store.all()).where(
          (t) => t.title.contains(title) || t.body.contains(title),
        )) {
          await tasks.remove(t);
        }
        if (await workspace.read(path) != null) await workspace.remove(path);
        fixtureThread ??= orb.activeId;
        if (fixtureThread != null && fixtureThread != active) {
          await orb.removeChat(fixtureThread!);
        }
        if (active != null) await orb.selectChat(active);
        await store.saveConfig(initialModel);
        await orb.setAutoMemoryEnabled(memoryWasOn);
      }
    },
    skip: _url.isEmpty || _model.isEmpty,
    timeout: const Timeout(Duration(minutes: 9)),
  );
}
