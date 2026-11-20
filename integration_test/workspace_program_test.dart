import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/orb_store.dart';
import 'package:orb_mobile/core/program_runtime.dart';
import 'package:orb_mobile/core/workspace.dart';
import 'package:orb_mobile/core/workspace_program.dart';
import 'package:orb_mobile/main.dart';

const _url = String.fromEnvironment('ORB_TEST_BASE_URL');
const _model = String.fromEnvironment('ORB_TEST_MODEL');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'chat runs a C program, repairs a failed check and saves the output',
    (tester) async {
      final store = OrbStore();
      final orb = OrbController(store: store);
      await tester.pumpWidget(OrbApp(controller: orb));

      Future<void> waitFor(bool Function() done) async {
        final elapsed = Stopwatch()..start();
        while (!done() && elapsed.elapsed < const Duration(seconds: 60)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          done(),
          isTrue,
          reason: 'Timed out waiting for Orb: ${orb.error}',
        );
      }

      await waitFor(() => orb.ready);
      final previousConfig = orb.config;
      final previousThread = orb.activeId;
      final memoryWasOn = orb.autoMemoryEnabled;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final project = 'orb-program-$stamp';
      final limit = 3 + stamp % 97;
      final sum = limit * (limit + 1) ~/ 2;
      final sourcePath = '$project/main.c';
      final outputPath = '$project/result.txt';
      final workspace = await Workspace.open();
      try {
        await orb.setAutoMemoryEnabled(false);
        await orb.saveConfig(ModelConfig(baseUrl: _url, model: _model));
        await orb.newChat();
        final composer = find.byKey(const ValueKey('composer'));
        await tester.enterText(
          composer,
          '请在项目 $project 检查求和程序，从 1 加到 $limit。运行后修好错误，把正确输出保存到 result.txt。',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('send')));
        await tester.pump();
        await waitFor(
          () =>
              !orb.busy &&
              (orb.error != null ||
                  orb.messages.lastOrNull?.role == 'assistant'),
        );
        expect(orb.error, isNull);
        await tester.pump();
        expect(find.text('工具执行 · 5'), findsOneWidget);

        final answer = (await orb.historyFor(orb.activeId!)).last;
        expect(answer.status, 'complete', reason: answer.text);
        expect(answer.text, contains('求和结果是 $sum'));
        final receipts = answer.metadata['localTools'] as List;
        expect(receipts.map((r) => r['name']), [
          'workspace_write',
          'workspace_run',
          'workspace_read',
          'workspace_edit',
          'workspace_run',
        ]);
        final runs = receipts.where((r) => r['name'] == 'workspace_run');
        expect(runs.map((r) => r['exit_code']), [7, 0]);
        expect(runs.map((r) => r['ok']), [false, true]);
        final saved = await Workspace.open();
        expect((await saved.read(sourcePath))?.text, contains('n * (n + 1)'));
        expect((await saved.read(outputPath))?.text, '$sum\n');
        debugPrint(
          'C program chat: first exit 7, repaired exit 0, saved sum $sum.',
        );
      } finally {
        final testThread = orb.activeId;
        if (testThread != null && testThread != previousThread) {
          await orb.removeChat(testThread);
        }
        if (previousThread != null) {
          await orb.selectChat(previousThread);
        } else {
          await orb.newChat();
        }
        await workspace.remove(sourcePath);
        await workspace.remove(outputPath);
        await store.saveConfig(previousConfig);
        await orb.setAutoMemoryEnabled(memoryWasOn);
      }
    },
    skip: _url.isEmpty || _model.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets('programs stay in their project and recover after timeout', (
    _,
  ) async {
    final workspace = await Workspace.open();
    final project = 'orb-limits-${DateTime.now().microsecondsSinceEpoch}';
    final looping = WorkFile(
      '$project/loop.c',
      'int main(void) { while (1) {} return 0; }',
    );
    final counter = WorkFile(
      '$project/bytes.c',
      '#include <stdio.h>\n'
          'int main(void) { int n=0; while (getchar()!=-1) n=n+1; printf("%d\\n",n); return 0; }',
    );
    final input = WorkFile('$project/input.txt', '沪\n');
    final outside = WorkFile('$project-other/input.txt', 'original');
    final output = '$project/result.txt';
    addTearDown(() async {
      for (final path in [
        looping.path,
        counter.path,
        input.path,
        outside.path,
        output,
      ]) {
        await workspace.remove(path);
      }
    });
    for (final file in [looping, counter, input, outside]) {
      await workspace.save(file);
    }
    for (final arguments in [
      {
        'path': counter.path,
        'input_paths': [outside.path],
        'output_path': output,
      },
      {'path': counter.path, 'output_path': outside.path},
    ]) {
      await expectLater(
        runStoredProgram(workspace, arguments),
        throwsA(
          isA<OrbException>().having(
            (e) => e.message,
            'message',
            contains('项目目录'),
          ),
        ),
      );
    }
    expect((await workspace.read(outside.path))?.text, outside.text);
    expect(await workspace.read(output), isNull);
    final stalled = await runStoredProgram(workspace, {
      'path': looping.path,
      'output_path': output,
    }).timeout(const Duration(seconds: 30));
    expect(stalled['phase'], 'run', reason: '$stalled');
    expect(stalled['exit_code'], 124, reason: '$stalled');
    expect(await workspace.read(output), isNull);
    final control = ProgramRunControl();
    final cancelled = expectLater(
      runStoredProgram(workspace, {
        'path': looping.path,
        'output_path': output,
      }, control: control).timeout(const Duration(seconds: 6)),
      throwsA(
        isA<OrbException>().having(
          (e) => e.message,
          'message',
          contains('已停止'),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    control.cancel();
    await cancelled;
    expect(await workspace.read(output), isNull);
    final recovered = await runStoredProgram(workspace, {
      'path': counter.path,
      'stdin_path': input.path,
      'output_path': output,
    });
    expect(recovered['exit_code'], 0, reason: '$recovered');
    expect(recovered['stdout'], '4\n');
    expect((await workspace.read(output))?.text, '4\n');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
