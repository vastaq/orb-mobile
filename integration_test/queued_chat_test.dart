import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/main.dart';
import 'package:orb_mobile/core/orb_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'a pending follow-up is cancellable, then delivered to the same conversation',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>(), questions = <String>[];
      server.listen((r) async {
        final payload = jsonDecode(await utf8.decoder.bind(r).join());
        questions.add(payload['messages'].last['content'] as String);
        final response = r.response
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..bufferOutput = false;
        response.write('data: {"choices":[{"delta":{"content":"本轮回答"}}]}\n\n');
        await response.flush();
        if (questions.length == 1) await release.future;
        response.write(
          'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":4}}\n\ndata: [DONE]\n\n',
        );
        await response.close();
      });
      final orb = OrbController();
      await orb.initialize();
      final old = orb.config,
          previous = orb.activeId,
          memory = orb.autoMemoryEnabled;
      await orb.setAutoMemoryEnabled(false);
      await orb.saveConfig(
        ModelConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'queue-fixture',
        ),
      );
      await orb.newChat();
      await tester.pumpWidget(OrbApp(controller: orb));
      final field = find.byKey(const ValueKey('composer')),
          send = find.byKey(const ValueKey('send'));
      Future<void> until(bool Function() condition) async {
        final timer = Stopwatch()..start();
        while (!condition() && timer.elapsed < const Duration(seconds: 15)) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(condition(), isTrue);
      }

      Future<void> typeMessage(String text) async {
        await tester.tap(field);
        await until(() => tester.widget<TextField>(field).focusNode!.hasFocus);
        await tester.enterText(field, text);
        await tester.pump();
        expect(tester.widget<TextField>(field).controller!.text, text);
      }

      try {
        await until(() => field.evaluate().isNotEmpty);
        await typeMessage('第一问');
        await tester.tap(send);
        await until(
          () => orb.busy && orb.messages.lastOrNull?.role == 'assistant',
        );
        final cancel = find.byTooltip('取消待发送');
        Future<void> queue(String text) async {
          await typeMessage(text);
          expect(tester.widget<IconButton>(send).tooltip, '排队发送');
          await tester.tap(send);
          await until(
            () => orb.queuedText == text && cancel.evaluate().isNotEmpty,
          );
        }

        await queue('取消的追问');
        await tester.tap(cancel);
        await until(() => orb.queuedText == null && cancel.evaluate().isEmpty);
        await queue('保留的追问');
        release.complete();
        await until(() => questions.length == 2 && !orb.busy);
        expect(questions, ['第一问', '保留的追问']);
        final messages = await orb.historyFor(orb.activeId!);
        expect(messages.map((m) => m.role), [
          'user',
          'assistant',
          'user',
          'assistant',
        ]);
        expect(messages.last.metadata['usage']['input'], 12);
      } finally {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
        if (orb.activeId != null) await orb.removeChat(orb.activeId!);
        if (previous != null) await orb.selectChat(previous);
        final store = OrbStore();
        await store.open();
        await store.saveConfig(old);
        await orb.setAutoMemoryEnabled(memory);
        await tester.pumpWidget(const SizedBox());
        orb.dispose();
      }
    },
  );
}
