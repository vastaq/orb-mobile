import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/chat_provider.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/workspace.dart';
import 'package:orb_mobile/core/workspace_program.dart';
import 'package:orb_mobile/main.dart';

import 'live_workspace_program_test.dart' show LiveTestStore, RelayedLiveConfig;

const _enabled = bool.fromEnvironment('ORB_REPAIR_BENCH');
const _task = String.fromEnvironment('ORB_REPAIR_TASK', defaultValue: 'all');
const _variant = String.fromEnvironment('ORB_REPAIR_VARIANT');
const _provider = String.fromEnvironment('ORB_LIVE_PROGRAM_PROVIDER');
const _model = String.fromEnvironment('ORB_LIVE_PROGRAM_MODEL');
const _port = int.fromEnvironment('ORB_LIVE_PROGRAM_PORT');
const _tasks = ['single', 'double', 'short'];

// Keep every byte outside the target tariff records, but allow any local
// implementation that quotes the correct prices, including different C syntax.
class _Tariffs {
  final protected = <String>[];
  final records = <String>[];
  late final String prompt, source, sampleOutput, hiddenInput, hiddenOutput;
  final String project;

  _Tariffs(String id) : project = 'bench-freight-$id' {
    final dual = id == 'double';
    final count = id == 'short' ? 4 : 160;
    final target = id == 'short' ? 3 : 147;
    String depot(int i) => 'S${i.toString().padLeft(3, '0')}';
    final code = depot(target);
    final chunk = StringBuffer('''#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct tariff { const char *depot; int base; int per_kg; };
''');
    int base(int i, bool holiday) => 100 + (i % 9) * 5 + (holiday ? 30 : 0);
    int perKg(int i) => 4 + (i % 4);
    for (final schedule in ['weekday', 'holiday']) {
      final holiday = schedule == 'holiday';
      chunk.writeln('\nstatic const struct tariff $schedule[] = {');
      for (var i = 1; i <= count; i++) {
        if ((i - 1) % 5 == 0) {
          chunk.writeln('  /* $schedule dispatch band ${(i - 1) ~/ 5 + 1} */');
        }
        final row =
            '  {"${depot(i)}",  /* depot */\n'
            '   ${base(i, holiday)}, ${perKg(i)}},  /* base, per kg */\n';
        if (i == target && (!holiday || dual)) {
          protected.add(chunk.toString());
          chunk.clear();
          records.add(row);
        } else {
          chunk.write(row);
        }
      }
      chunk.writeln('};');
    }
    chunk.write(r'''
// One quote per input line, for example W S001 3 or H S001 3.
int main(void) {
  char line[80];
  while (fgets(line, sizeof line, stdin)) {
    if ((line[0] != 'W' && line[0] != 'H') || line[1] != ' ') return 2;
    char *station = line + 2;
    char *weight = strchr(station, ' ');
    if (weight == NULL) return 2;
    *weight++ = '\0';
    int kg = atoi(weight);
    if (kg <= 0) return 2;
    const struct tariff *rates = line[0] == 'W' ? weekday : holiday;
    int n = sizeof weekday / sizeof weekday[0];
    int found = 0;
    for (int i = 0; i < n; i++) {
      if (strcmp(station, rates[i].depot) == 0) {
        printf("%d\n", rates[i].base + kg * rates[i].per_kg);
        found = 1;
        break;
      }
    }
    if (!found) return 3;
  }
  return 0;
}
''');
    protected.add(chunk.toString());
    source = [
      for (var i = 0; i < records.length; i++) ...[protected[i], records[i]],
      protected.last,
    ].join();
    final newBase = dual ? 206 : 187;
    const newHolidayPerKg = 14;
    prompt =
        '在手机工作区的 $project/main.c 更新站点 $code 的配送价。'
        '工作日的起步费改成 $newBase 分，'
        '${dual ? '节假日的每公斤单价改成 $newHolidayPerKg 分。' : '节假日价格照旧。'}'
        '只改对应费率记录，保留其他费率、计算逻辑、文件排版和项目说明。'
        '用程序分别算该站工作日和节假日各 3 公斤的报价，'
        '输入为两行「W $code 3」和「H $code 3」。'
        '请将这次运行的标准输出保存到同项目的 quote.txt。';
    int price(int i, bool h, int weight) =>
        (i == target && !h ? newBase : base(i, h)) +
        weight * (i == target && h && dual ? newHolidayPerKg : perKg(i));
    sampleOutput = '${price(target, false, 3)}\n${price(target, true, 3)}\n';
    hiddenInput =
        'H $code 11\nW $code 8\nW ${depot(target - 1)} 2\nH ${depot(target + 1)} 6\n';
    hiddenOutput =
        '${price(target, true, 11)}\n${price(target, false, 8)}\n'
        '${price(target - 1, false, 2)}\n${price(target + 1, true, 6)}\n';
  }

  bool preservesSurroundings(String edited) {
    if (!edited.startsWith(protected.first) ||
        !edited.endsWith(protected.last)) {
      return false;
    }
    var at = protected.first.length;
    for (final middle in protected.skip(1).take(protected.length - 2)) {
      final next = edited.indexOf(middle, at);
      if (next < at) return false;
      at = next + middle.length;
    }
    return at <= edited.length - protected.last.length;
  }
}

const _manifest =
    'Freight rate ledger\nInput: W or H, depot, weight in kg.\nPrices are integer cents.\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // A misspelled selector must not silently turn a requested run into zero cases.
  if (_enabled && ![..._tasks, 'all'].contains(_task)) {
    throw ArgumentError(
      'ORB_REPAIR_TASK must be single, double, short, or all.',
    );
  }
  for (final id in _tasks.where((id) => _task == 'all' || _task == id)) {
    testWidgets(
      'workspace repair benchmark ($id)',
      (tester) async {
        final preset = switch (_provider) {
          'deepseek' => ModelConfig.deepSeek,
          'openai' => ModelConfig.openAI,
          _ => throw ArgumentError('Select deepseek or openai.'),
        };
        expect(['baseline', 'candidate'], contains(_variant));
        expect(_model.trim(), isNotEmpty);
        expect(_port, inInclusiveRange(1, 65535));
        final task = _Tariffs(id);
        final project = task.project,
            entry = '$project/main.c',
            manifest = '$project/README.txt',
            output = '$project/quote.txt';
        final rounds = <Map<String, int>?>[];
        final config = RelayedLiveConfig(preset.baseUrl, _model, _port);
        final provider = StreamingChatProvider(
          usagePurpose: 'benchmark',
          recordUsage: (_, _, counts) async => rounds.add(counts),
        );
        final orb = OrbController(
          store: LiveTestStore(config),
          provider: provider,
        );
        final checks = {
          for (final key in [
            'turn_complete',
            'run_receipt',
            'saved_output',
            'unchanged_context',
            'unchanged_manifest',
            'hidden_cases',
          ])
            key: false,
        };
        final failures = <String>[];
        final tools = <String, int>{};
        var failedTools = 0;
        final elapsed = Stopwatch();
        bool seeded = false, startedChat = false;
        final workspace = await Workspace.open();
        String? previousThread;
        Future<bool> waitFor(bool Function() ready, Duration limit) async {
          final clock = Stopwatch()..start();
          while (!ready() && clock.elapsed < limit) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          return ready();
        }

        try {
          if ((await workspace.paths()).any(
            (p) => p == project || p.startsWith('$project/'),
          )) {
            failures.add('project_already_exists');
          } else {
            await workspace.save(WorkFile(entry, task.source));
            seeded = true;
            await workspace.save(WorkFile(manifest, _manifest));
            await tester.pumpWidget(OrbApp(controller: orb));
            if (!await waitFor(
                  () => orb.ready || orb.error != null,
                  const Duration(seconds: 30),
                ) ||
                !orb.ready) {
              failures.add('initialization');
            } else {
              previousThread = orb.activeId;
              await orb.newChat();
              startedChat = true;
              await tester.enterText(
                find.byKey(const ValueKey('composer')),
                task.prompt,
              );
              await tester.pump();
              elapsed.start();
              await tester.tap(find.byKey(const ValueKey('send')));
              await tester.pump();
              final done = await waitFor(
                () =>
                    !orb.busy &&
                    (orb.error != null ||
                        orb.messages.lastOrNull?.role == 'assistant'),
                const Duration(minutes: 7),
              );
              elapsed.stop();
              if (!done) {
                failures.add('timeout');
                orb.stop();
              }
              final current = orb.activeId;
              final history = current == null
                  ? <OrbMessage>[]
                  : await orb.historyFor(current);
              final answer = history
                  .where((m) => m.role == 'assistant')
                  .lastOrNull;
              final receipts = (answer?.metadata['localTools'] as List? ?? [])
                  .whereType<Map>();
              for (final r in receipts) {
                final rawName = r['name'];
                final name =
                    rawName is String &&
                        RegExp(r'^workspace_[a-z_]{1,32}$').hasMatch(rawName)
                    ? rawName
                    : 'other';
                tools.update(name, (n) => n + 1, ifAbsent: () => 1);
                if (r['ok'] != true) failedTools++;
              }
              checks['turn_complete'] =
                  done &&
                  orb.error == null &&
                  answer?.status == 'complete' &&
                  history.where((m) => m.role == 'user').length == 1;
              if (orb.error != null) {
                failures.add(
                  orb.error!.contains('工具调用上限')
                      ? 'tool_limit'
                      : 'provider_or_chat_error',
                );
              }
              checks['run_receipt'] = receipts.any(
                (r) =>
                    r['name'] == 'workspace_run' &&
                    r['path'] == entry &&
                    r['ok'] == true &&
                    r['phase'] == 'run' &&
                    r['exit_code'] == 0 &&
                    r['output_path'] == output &&
                    r['stdout'] == task.sampleOutput,
              );
              checks['saved_output'] =
                  (await workspace.read(output))?.text == task.sampleOutput;
              checks['unchanged_manifest'] =
                  (await workspace.read(manifest))?.text == _manifest;
              final source = await workspace.read(entry);
              checks['unchanged_context'] =
                  source != null && task.preservesSurroundings(source.text);
              if (source != null && done) {
                final result = await runStoredProgram(workspace, {
                  'path': entry,
                  'stdin': task.hiddenInput,
                });
                checks['hidden_cases'] =
                    result['phase'] == 'run' &&
                    result['exit_code'] == 0 &&
                    result['stdout'] == task.hiddenOutput;
              }
            }
          }
        } catch (_) {
          failures.add('benchmark_exception');
        } finally {
          if (startedChat) {
            final thread = orb.activeId;
            await orb.newChat();
            if (thread != null && thread != previousThread) {
              await orb.removeChat(thread);
            }
            if (previousThread != null) await orb.selectChat(previousThread);
          }
          if (seeded) {
            for (final path in await workspace.paths()) {
              if (path.startsWith('$project/')) await workspace.remove(path);
            }
          }
        }
        failures.addAll(checks.keys.where((key) => !checks[key]!));
        final allUsage = rounds.isNotEmpty && rounds.every((r) => r != null);
        int? total(String key) =>
            allUsage ? rounds.fold<int>(0, (n, r) => n + r![key]!) : null;
        debugPrint(
          'ORB_REPAIR_BENCH_RESULT ${jsonEncode({'task': id, 'variant': _variant, 'provider': _provider, 'model': _model, 'passed': failures.isEmpty, 'failures': failures, ...checks, 'source_bytes': utf8.encode(task.source).length, 'rounds': rounds.length, 'usage_rounds': rounds.whereType<Map>().length, 'input_tokens': total('input'), 'output_tokens': total('output'), 'cached_input_tokens': total('cached'), 'tools': tools, 'tool_calls': tools.values.fold<int>(0, (a, b) => a + b), 'failed_tool_calls': failedTools, 'chat_ms': elapsed.elapsedMilliseconds})}',
        );
        expect(failures, isEmpty);
      },
      skip: !_enabled,
      timeout: const Timeout(Duration(minutes: 9)),
    );
  }
}
