import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/workspace.dart';
import 'package:orb_mobile/core/workspace_program.dart';

import 'live_workspace_program_test.dart' show LiveTestStore, RelayedLiveConfig;

const _live = bool.fromEnvironment('ORB_LIVE_JAVASCRIPT');
const _port = int.fromEnvironment('ORB_LIVE_PROGRAM_PORT');
const _model = String.fromEnvironment(
  'ORB_LIVE_PROGRAM_MODEL',
  defaultValue: 'deepseek-flash',
);

const _join = r'''
const labels = new Map(readText('labels.tsv').trim().split(/\r?\n/).slice(1).map(row => row.split('\t')));
const selected = readStdin().trim();
const amounts = new Map();
for (const row of readText('orders.tsv').trim().split(/\r?\n/).slice(1)) {
  const [sku, action, count] = row.split('\t');
  if (action === selected) amounts.set(sku, (amounts.get(sku) || 0) + Number(count));
}
console.log('货号\t商品\t件数');
for (const sku of [...amounts.keys()].sort()) {
  console.log([sku, labels.get(sku), amounts.get(sku)].join('\t'));
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'saved JavaScript joins selected UTF-8 files and preserves full output',
    (_) async {
      final workspace = await Workspace.open();
      final dir = 'js-warehouse-${DateTime.now().microsecondsSinceEpoch}';
      final script = WorkFile('$dir/join.js', _join);
      final labels = StringBuffer('货号\t商品\r\n');
      final orders = StringBuffer('货号\t动作\t件数\n');
      final expected = StringBuffer('货号\t商品\t件数\n');
      for (var i = 0; i < 650; i++) {
        final sku = 'S${i.toString().padLeft(3, '0')}';
        labels.write('$sku\t纸鹤套装🌿$i\r\n');
        orders.write('$sku\t发货\t1\n$sku\t发货\t2\n');
        expected.write('$sku\t纸鹤套装🌿$i\t3\n');
      }
      final orderFile = WorkFile('$dir/orders.tsv', orders.toString());
      final filter = WorkFile('$dir/action.txt', '发货\n');
      final output = '$dir/report.tsv';
      Future<Map<String, dynamic>> run(
        List<String> inputs, {
        String? previous,
      }) => runStoredProgram(workspace, {
        'path': script.path,
        'input_paths': inputs,
        'stdin_path': 'action.txt',
        'output_path': 'report.tsv',
        'expected_output_hash': ?previous,
      });
      addTearDown(() async {
        for (final path in await workspace.paths()) {
          if (path.startsWith('$dir/')) await workspace.remove(path);
        }
      });
      for (final file in [
        script,
        WorkFile('$dir/labels.tsv', labels.toString()),
        orderFile,
        filter,
      ]) {
        await workspace.save(file);
      }
      const inputs = ['orders.tsv', 'labels.tsv'];
      final first = await run(inputs);
      expect(first['exit_code'], 0, reason: first['stderr'] as String?);
      expect(first['stdout_truncated'], true);
      expect(first['output_path'], output);
      final persisted = (await (await Workspace.open()).read(output))!;
      expect(persisted.text, expected.toString());
      expect(first['output_sha256'], persisted.hash);

      await workspace.save(
        WorkFile(orderFile.path, '${orders}S649\t退货\t8\nS001\t退货\t2\n'),
        previous: orderFile.hash,
      );
      await workspace.save(
        WorkFile(filter.path, '退货\n'),
        previous: filter.hash,
      );
      final again = await run(inputs, previous: persisted.hash);
      expect(again['exit_code'], 0, reason: again['stderr'] as String?);
      const replacement = '货号\t商品\t件数\nS001\t纸鹤套装🌿1\t2\nS649\t纸鹤套装🌿649\t8\n';
      final second = (await (await Workspace.open()).read(output))!;
      expect(again['stdout'], replacement);
      expect(second.text, replacement);
      expect((await workspace.read(script.path))?.hash, script.hash);

      // The file still exists in this project but was withheld from this run.
      final denied = await run(['orders.tsv'], previous: second.hash);
      expect(denied['exit_code'], isNot(0));
      expect(denied['stderr'], isNotEmpty);
      expect(denied, isNot(contains('output_path')));
      expect((await (await Workspace.open()).read(output))?.hash, second.hash);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'DeepSeek writes and runs reusable JavaScript from one chat message',
    (_) async {
      expect(_port, inInclusiveRange(1, 65535));
      final orb = OrbController(
        store: LiveTestStore(
          RelayedLiveConfig(ModelConfig.deepSeek.baseUrl, _model, _port),
        ),
      );
      final workspace = await Workspace.open();
      final dir = 'js-returns-${DateTime.now().microsecondsSinceEpoch}';
      final source = '$dir/totals.js';
      final output = '$dir/result.tsv';
      final data = WorkFile(
        '$dir/returns.tsv',
        '门店\t件数\n南站\t4\n北站\t3\n南站\t2\n',
      );
      await orb.initialize();
      final previous = orb.activeId;
      try {
        await orb.newChat();
        await workspace.save(data);
        await orb
            .send(
              '请在手机工作区 $dir 写一个可复用的 JavaScript 小工具 totals.js，读取本项目 returns.tsv，按门店汇总退货件数，以门店 Unicode 升序输出两列制表符表（表头沿用输入、每行含结尾换行），在手机运行并将程序输出存成 result.tsv。',
            )
            .timeout(const Duration(minutes: 4));
        expect(orb.error, isNull);
        final history = await orb.historyFor(orb.activeId!);
        expect(history.where((m) => m.role == 'user'), hasLength(1));
        final answer = history.last;
        expect(answer.status, 'complete', reason: answer.text);
        expect(answer.metadata['provider'], ModelConfig.deepSeek.service.name);
        final receipts = (answer.metadata['localTools'] as List? ?? [])
            .whereType<Map>()
            .toList();
        final steps = receipts.map((r) => r['name']).join(' → ');
        debugPrint('JavaScript live $_model: $steps');
        expect(
          receipts.any(
            (r) =>
                r['name'] == 'workspace_write' &&
                r['path'] == source &&
                r['ok'] == true,
          ),
          isTrue,
          reason: steps,
        );
        expect(
          receipts.any(
            (r) =>
                r['name'] == 'workspace_run' &&
                r['path'] == source &&
                r['output_path'] == output &&
                r['exit_code'] == 0,
          ),
          isTrue,
          reason: '$steps; ${answer.text}',
        );
        final saved = await Workspace.open();
        expect((await saved.read(output))?.text, '门店\t件数\n北站\t3\n南站\t6\n');
        final hash = (await saved.read(source))!.hash;
        await saved.save(
          WorkFile(data.path, '门店\t件数\n西站\t7\n东站\t4\n西站\t5\n'),
          previous: data.hash,
        );
        final rerun = await runStoredProgram(saved, {
          'path': source,
          'input_paths': ['returns.tsv'],
          'stdin_path': 'returns.tsv',
        });
        expect(rerun['exit_code'], 0, reason: rerun['stderr'] as String?);
        expect(rerun['stdout'], '门店\t件数\n东站\t4\n西站\t12\n');
        expect((await saved.read(source))?.hash, hash);
      } finally {
        final id = orb.activeId;
        if (id != null && id != previous) await orb.removeChat(id);
        if (previous != null) await orb.selectChat(previous);
        for (final path in await workspace.paths()) {
          if (path.startsWith('$dir/')) await workspace.remove(path);
        }
        orb.dispose();
      }
    },
    skip: !_live,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
