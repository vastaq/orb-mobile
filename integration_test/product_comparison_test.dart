import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/chat_provider.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/workspace.dart';
import 'package:path_provider/path_provider.dart';

import 'live_workspace_program_test.dart' show LiveTestStore, RelayedLiveConfig;

// Only public prompts and initial files are served to the device. The independent
// grader reads the exported final state on the host after the conversation ends.
const _suitePort = int.fromEnvironment('ORB_PRODUCT_SUITE_PORT');
const _selector = String.fromEnvironment(
  'ORB_PRODUCT_TASK',
  defaultValue: 'all',
);
const _apiPort = int.fromEnvironment('ORB_LIVE_PROGRAM_PORT');
const _model = String.fromEnvironment('ORB_LIVE_PROGRAM_MODEL');
const _provider = String.fromEnvironment('ORB_LIVE_PROGRAM_PROVIDER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'run the public workspace tasks with Orb',
    (_) async {
      final base = switch (_provider) {
        'deepseek' => ModelConfig.deepSeek.baseUrl,
        'openai' => ModelConfig.openAI.baseUrl,
        _ => throw ArgumentError('Select a test provider.'),
      };
      final client = HttpClient();
      final List<dynamic> cases;
      try {
        final request = await client.getUrl(
          Uri.http('127.0.0.1:$_suitePort', '/public.json'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        cases = jsonDecode(
          await utf8.decoder.bind(response).join(),
        ) as List<dynamic>;
      } finally {
        client.close(force: true);
      }
      final selected = cases.where(
        (row) => _selector == 'all' || row['id'] == _selector,
      );
      expect(selected, isNotEmpty);
      final workspace = await Workspace.open();
      final root = await getApplicationDocumentsDirectory();
      final output = await Directory('${root.path}/orb-product-comparison')
          .create(recursive: true);
      for (final row in selected) {
        final id = row['id'] as String;
        expect(RegExp(r'^[a-z0-9-]+$').hasMatch(id), isTrue);
        expect(
          await workspace.paths(),
          isEmpty,
          reason: 'Use a dedicated empty simulator workspace.',
        );
        final usage = <Map<String, int>?>[];
        final orb = OrbController(
          store: LiveTestStore(RelayedLiveConfig(base, _model, _apiPort)),
          provider: StreamingChatProvider(
            usagePurpose: 'product comparison',
            recordUsage: (_, _, values) async => usage.add(values),
          ),
        );
        String? previous, testThread;
        var timedOut = false;
        try {
          for (final entry in (row['files'] as Map).entries) {
            await workspace.save(
              WorkFile(entry.key as String, entry.value as String),
            );
          }
          await orb.initialize();
          previous = orb.activeId;
          await orb.newChat();
          try {
            await orb
                .send(row['prompt'] as String)
                .timeout(const Duration(minutes: 9));
          } on TimeoutException {
            timedOut = true;
            orb.stop();
          }
          testThread = orb.activeId;
          final answer = testThread == null
              ? null
              : (await orb.historyFor(testThread))
                    .where((m) => m.role == 'assistant')
                    .lastOrNull;
          final receipts = (answer?.metadata['localTools'] as List? ?? [])
              .whereType<Map>();
          final paths = await workspace.paths();
          final files = <String, String>{};
          for (final path in paths) {
            files[path] = (await workspace.read(path))!.text;
          }
          await File('${output.path}/$id.json')
              .writeAsString(jsonEncode(files));
          int? total(String k) =>
              usage.isNotEmpty && usage.every((u) => u != null)
              ? usage.fold<int>(0, (a, b) => a + b![k]!)
              : null;
          final metrics = {
            'id': id,
            'model': _model,
            'rounds': usage.length,
            'input_tokens': total('input'),
            'output_tokens': total('output'),
            'timeout': timedOut,
            'complete': answer?.status == 'complete' && orb.error == null,
            'tools': [
              for (final receipt in receipts)
                {'name': receipt['name'], 'ok': receipt['ok']},
            ],
          };
          await File('${output.path}/$id.metrics.json')
              .writeAsString(jsonEncode(metrics));
          printOnFailure('See $id.metrics.json for the final activity.');
          // A task failure is scored from final files and does not skip later cases.
          // The host needs this marker to distinguish a completed trial from a transport failure.
          // ignore: avoid_print
          print('ORB_PRODUCT_TRIAL ${jsonEncode(metrics)}');
        } finally {
          await orb.newChat(); // settles an interrupted turn before cleaning its files
          if (testThread != null && testThread != previous) {
            await orb.removeChat(testThread);
          }
          if (previous != null) await orb.selectChat(previous);
          for (final path in await workspace.paths()) {
            await workspace.remove(path);
          }
          orb.dispose();
        }
      }
    },
    skip: _suitePort == 0,
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
