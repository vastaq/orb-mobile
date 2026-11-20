import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/orb_store.dart';
import 'package:orb_mobile/core/workspace.dart';
import 'package:orb_mobile/core/workspace_program.dart';
import 'package:orb_mobile/main.dart';

// Run explicitly on a dedicated simulator with a loopback route to the Mac
// provider_test_proxy. Only the proxy needs the provider credential.
const _enabled = bool.fromEnvironment('ORB_LIVE_PROGRAM');
const _provider = String.fromEnvironment('ORB_LIVE_PROGRAM_PROVIDER');
const _model = String.fromEnvironment('ORB_LIVE_PROGRAM_MODEL');
const _port = int.fromEnvironment('ORB_LIVE_PROGRAM_PORT');

// Keep the production service selection, wire format and streaming parser.
// Route only the completed request URL to the local test proxy.
class _RelayedConfig extends ModelConfig {
  _RelayedConfig(String baseUrl)
    : super(baseUrl: baseUrl, model: _model, apiKey: 'orb-test-placeholder');

  @override
  Uri get endpoint => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _port,
    path: super.endpoint.path,
  );
}

// Keep chat history and tool receipts on the normal database. Supply only
// test configuration and context, without opening active provider credentials.
class _LiveTestStore extends OrbStore {
  _LiveTestStore(this.config);
  final ModelConfig config;

  @override
  Future<ModelConfig> loadConfig() async => config;

  @override
  Future<Map<String, ModelConfig>> loadProfiles() async => {};

  @override
  Future<List<OrbMemory>> memories() async => [];

  @override
  Future<String?> preference(String name) async =>
      name == 'auto_memory' ? '0' : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'live provider creates and runs a reusable C tool from one chat message',
    (tester) async {
      final preset = switch (_provider) {
        'openai' => ModelConfig.openAI,
        'deepseek' => ModelConfig.deepSeek,
        _ => throw ArgumentError(
          'ORB_LIVE_PROGRAM_PROVIDER must be openai or deepseek.',
        ),
      };
      expect(_model.trim(), isNotEmpty, reason: 'Set ORB_LIVE_PROGRAM_MODEL.');
      expect(
        _port,
        inInclusiveRange(1, 65535),
        reason: 'Set ORB_LIVE_PROGRAM_PORT.',
      );
      final config = _RelayedConfig(preset.baseUrl);
      final orb = OrbController(store: _LiveTestStore(config));
      await tester.pumpWidget(OrbApp(controller: orb));

      Future<void> waitFor(bool Function() done, Duration timeout) async {
        final elapsed = Stopwatch()..start();
        while (!done() && elapsed.elapsed < timeout) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(done(), isTrue, reason: 'Orb did not finish within $timeout.');
      }

      await waitFor(
        () => orb.ready || orb.error != null,
        const Duration(seconds: 30),
      );
      expect(orb.ready, isTrue);
      final previousThread = orb.activeId;
      final workspace = await Workspace.open();
      final project = 'digits-${DateTime.now().microsecondsSinceEpoch}';
      final entry = '$project/main.c';
      final output = '$project/result.txt';
      try {
        await orb.newChat();
        expect(await workspace.read(entry), isNull);
        expect(await workspace.read(output), isNull);
        await tester.enterText(
          find.byKey(const ValueKey('composer')),
          '请在手机工作区 $entry 写一个可以重复使用的 C 小工具。'
          '输入一段文字，它返回一个整数，表示所有数字字符合计出现了几次。'
          '请用 A7b25X4 试跑，把输出的一个整数和换行保存成项目里的 result.txt，然后告诉我结果。'
          '以后我还要换一段文字再用。',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('send')));
        await tester.pump();
        await waitFor(
          () =>
              !orb.busy &&
              (orb.error != null ||
                  orb.messages.lastOrNull?.role == 'assistant'),
          const Duration(minutes: 4),
        );
        expect(orb.error, isNull);
        final history = await orb.historyFor(orb.activeId!);
        expect(
          history.where((message) => message.role == 'user'),
          hasLength(1),
        );
        final answer = history.last;
        expect(answer.role, 'assistant');
        expect(answer.status, 'complete');
        expect(answer.metadata['provider'], preset.service.name);
        final receipts = (answer.metadata['localTools'] as List? ?? [])
            .whereType<Map>();
        expect(
          receipts.any(
            (r) =>
                r['name'] == 'workspace_write' &&
                r['path'] == entry &&
                r['ok'] == true,
          ),
          isTrue,
          reason: 'Expected a successful source write in the chat receipts.',
        );
        expect(
          receipts.any(
            (r) =>
                r['name'] == 'workspace_run' &&
                r['path'] == entry &&
                r['ok'] == true &&
                r['phase'] == 'run' &&
                r['exit_code'] == 0 &&
                r['stdout'] == '4\n' &&
                r['output_path'] == output,
          ),
          isTrue,
          reason: 'Expected the on-device run to save stdout in result.txt.',
        );
        final source = await workspace.read(entry);
        expect(source, isNotNull);
        expect((await workspace.read(output))?.text, '4\n');

        final second = await runStoredProgram(workspace, {
          'path': entry,
          'stdin': 'end9',
        });
        expect(second['phase'], 'run');
        expect(second['exit_code'], 0);
        expect(second['stdout'], '1\n');
        expect((await workspace.read(entry))?.hash, source!.hash);
        debugPrint(
          'Live ${preset.label}: ${receipts.map((r) => r['name']).join(' → ')}. Saved 4; same source returned 1 on new input.',
        );
      } finally {
        final testThread = orb.activeId;
        await orb.newChat();
        if (testThread != null && testThread != previousThread) {
          await orb.removeChat(testThread);
        }
        if (previousThread != null) await orb.selectChat(previousThread);
        for (final path in await workspace.paths()) {
          if (path.startsWith('$project/')) await workspace.remove(path);
        }
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
