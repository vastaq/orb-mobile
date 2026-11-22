import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/workspace.dart';

import 'live_workspace_program_test.dart' show LiveTestStore, RelayedLiveConfig;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'DeepSeek searches a public source and saves it on the phone',
    (_) async {
      const port = int.fromEnvironment('ORB_LIVE_PROGRAM_PORT');
      final orb = OrbController(
        store: LiveTestStore(
          RelayedLiveConfig(
            ModelConfig.deepSeek.baseUrl,
            'deepseek-flash',
            port,
          ),
        ),
      );
      final workspace = await Workspace.open();
      final path = 'search-uat/${DateTime.now().microsecondsSinceEpoch}/pub.md';
      await orb.initialize();
      final previous = orb.activeId;
      try {
        expect(orb.search, isTrue);
        await orb.newChat();
        await orb.send(
          '请先联网搜索 Dart 官方文档，核实从 pubspec.yaml 获取依赖所用的 Dart 命令，'
          '然后把命令和查到的官方文档 HTTPS 链接写进手机工作区 $path。',
        );
        expect(orb.error, isNull);
        final history = await orb.historyFor(orb.activeId!);
        final answer = history.last;
        expect(answer.status, 'complete', reason: answer.text);
        final local = (answer.metadata['localTools'] as List? ?? [])
            .whereType<Map>();
        expect(
          local.any(
            (step) => step['name'] == 'workspace_write' && step['ok'] == true,
          ),
          isTrue,
          reason: '$local',
        );
        final citations = (answer.metadata['citations'] as List? ?? [])
            .whereType<Map>();
        expect(
          citations.any((c) => Uri.tryParse('${c['url']}')?.host == 'dart.dev'),
          isTrue,
          reason: '$citations',
        );
        final file = (await workspace.read(path))!;
        expect(file.text.toLowerCase(), contains('dart pub get'));
        expect(file.text, contains('https://dart.dev/'));
        // ignore: avoid_print
        print(
          'ORB_SEARCH_AND_LOCAL_WRITE citations=${citations.length} sha256=${file.hash}',
        );
      } finally {
        await workspace.remove(path);
        final id = orb.activeId;
        if (id != null && id != previous) await orb.removeChat(id);
        if (previous != null) await orb.selectChat(previous);
        orb.dispose();
      }
    },
    skip:
        !const bool.fromEnvironment('ORB_LIVE_WEB_WORKSPACE') ||
        const int.fromEnvironment('ORB_LIVE_PROGRAM_PORT') == 0,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
