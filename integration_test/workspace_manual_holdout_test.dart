import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/chat_provider.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/workspace.dart';

import 'live_workspace_program_test.dart' show LiveTestStore, RelayedLiveConfig;

const _enabled = bool.fromEnvironment('ORB_REPAIR_BENCH');
const _variant = String.fromEnvironment('ORB_REPAIR_VARIANT');
const _provider = String.fromEnvironment('ORB_LIVE_PROGRAM_PROVIDER');
const _model = String.fromEnvironment('ORB_LIVE_PROGRAM_MODEL');
const _port = int.fromEnvironment('ORB_LIVE_PROGRAM_PORT');

const _project = 'exhibit-returns';
const _handbook = '$_project/field-manual.md';
const _card = '$_project/desk-card.txt';
const _section = 'Glass slide return';
const _prompt =
    '请更新手机工作区 $_handbook 的「$_section」一节。这个展位的 Return drawer '
    '换成 DR-42，Label rack 换成 RK-65。只更新这两个编号，其他文字和排版原样保留。'
    '另外请把新的 Return drawer 编号和该节沿用的 Verification card 编号'
    '按这个顺序分两行写进 $_card，方便交班时查看。';

const _stations = [
  'Paper mask display',
  'Clay sample desk',
  'Print folio collection',
  'Folded maps',
  'Swatch wall',
  'Paper lantern return',
  'Stencil trays',
  'Marker samples',
  'Dye cards',
  'Slate tiles',
  'Metal rubbings',
  'Wax casts',
  'Shell prints',
  'Weaving samples',
  'Box labels',
  'Porcelain tiles',
  'Mosaic samples',
  'Ink proofs',
  'Book jackets',
  'Transfer sheets',
  'Shadow screens',
  'Resin tokens',
  'Letter blocks',
  'Colour wheels',
  _section,
  'Frame corners',
  'Tool silhouettes',
];

class _Manual {
  final lines = <String>['# Field manual for a traveling exhibit', ''];
  late final int drawer, rack;
  late final String checkCode;

  _Manual() {
    for (var i = 0; i < _stations.length; i++) {
      final station = _stations[i];
      final card = 'VC-${117 + 13 * i}';
      lines.addAll([
        '## $station',
        '',
        'At opening, match the tray label to the current exhibit list. '
            'Keep the cleared work surface on the aisle side.',
      ]);
      if (station == _section) drawer = lines.length;
      lines.addAll([
        '- Return drawer: DR-18',
        '- Station ticket: ST-${30 + i}',
        'Before shelving, check the packing slip against the object count.',
      ]);
      if (station == _section) {
        rack = lines.length;
        checkCode = card;
      }
      lines.addAll([
        '- Label rack: RK-04',
        '- Verification card: $card',
        '',
        'At closing, leave the station ticket with the completed slip and '
            'record missing labels in the exhibit register.',
        '',
      ]);
    }
  }

  Map<String, bool> assess(String? edited, String? output) {
    final rows = edited?.split('\n') ?? const <String>[];
    final pairs = (output ?? '').trim().split(RegExp(r'\r?\n'));
    // Markdown emphasis, bullets, spacing, case and hyphen glyphs can vary
    // on the two edited rows and desk card. All surrounding text stays exact.
    String plain(String s) => s
        .toUpperCase()
        .replaceAll(RegExp(r'^\s*[-+*]\s+'), '')
        .replaceAll(RegExp(r'[\s*_\x60:：＝=]'), '')
        .replaceAll(RegExp('[‐‑–－]'), '-');
    bool field(int at, String label, String value) =>
        at < rows.length && plain(rows[at]) == plain('$label: $value');
    bool cardValue(String row, String label, String code) =>
        plain(row) == plain(code) || plain(row) == plain('$label: $code');
    return {
      'updated_drawer': field(drawer, 'Return drawer', 'DR-42'),
      'updated_rack': field(rack, 'Label rack', 'RK-65'),
      'protected_text':
          rows.length == lines.length &&
          Iterable<int>.generate(lines.length)
              .every((i) => i == drawer || i == rack || rows[i] == lines[i]),
      'desk_card':
          pairs.length == 2 &&
          cardValue(pairs[0], 'Return drawer', 'DR-42') &&
          cardValue(pairs[1], 'Verification card', checkCode),
    };
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'held-out field manual update and handoff card',
    (_) async {
      final preset = switch (_provider) {
        'deepseek' => ModelConfig.deepSeek,
        'openai' => ModelConfig.openAI,
        _ => throw ArgumentError('Select deepseek or openai.'),
      };
      expect(['baseline', 'candidate'], contains(_variant));
      expect(_model.trim(), isNotEmpty);
      expect(_port, inInclusiveRange(1, 65535));
      final usage = <Map<String, int>?>[];
      final orb = OrbController(
        store: LiveTestStore(RelayedLiveConfig(preset.baseUrl, _model, _port)),
        provider: StreamingChatProvider(
          usagePurpose: 'holdout',
          recordUsage: (_, _, v) async => usage.add(v),
        ),
      );
      final workspace = await Workspace.open(), manual = _Manual();
      final original = manual.lines.join('\n');
      final tools = <String, int>{};
      final failures = <String>[];
      var checks = manual.assess(null, null), failuresInTools = 0;
      var seeded = false, startedChat = false, completed = false;
      String? previous;
      final elapsed = Stopwatch();
      try {
        if ((await workspace.paths()).any(
          (p) => p == _project || p.startsWith('$_project/'),
        )) {
          failures.add('project_already_exists');
        } else {
          await workspace.save(WorkFile(_handbook, original));
          seeded = true;
          await orb.initialize();
          if (!orb.ready) throw StateError('initialization');
          previous = orb.activeId;
          await orb.newChat();
          startedChat = true;
          elapsed.start();
          try {
            await orb.send(_prompt).timeout(const Duration(minutes: 7));
          } on TimeoutException {
            failures.add('timeout');
            orb.stop();
          } finally {
            elapsed.stop();
          }
          final thread = orb.activeId;
          final history = thread == null
              ? <OrbMessage>[]
              : await orb.historyFor(thread);
          final answer = history.where((m) => m.role == 'assistant').lastOrNull;
          completed =
              orb.error == null &&
              answer?.status == 'complete' &&
              history.where((m) => m.role == 'user').length == 1;
          if (orb.error case final String error) {
            failures.add(
              error.contains('工具调用上限')
                  ? 'tool_limit'
                  : 'provider_or_chat_error',
            );
          }
          for (final r
              in (answer?.metadata['localTools'] as List? ?? [])
                  .whereType<Map>()) {
            final raw = r['name'];
            final name =
                raw is String &&
                    RegExp(r'^workspace_[a-z_]{1,32}$').hasMatch(raw)
                ? raw
                : 'other';
            tools.update(name, (n) => n + 1, ifAbsent: () => 1);
            if (r['ok'] != true) failuresInTools++;
          }
          checks = manual.assess(
            (await workspace.read(_handbook))?.text,
            (await workspace.read(_card))?.text,
          );
        }
      } catch (_) {
        failures.add('benchmark_exception');
      } finally {
        if (startedChat) {
          final thread = orb.activeId;
          await orb.newChat();
          if (thread != null && thread != previous) {
            await orb.removeChat(thread);
          }
          if (previous != null) await orb.selectChat(previous);
        }
        if (seeded) {
          for (final p in await workspace.paths()) {
            if (p.startsWith('$_project/')) await workspace.remove(p);
          }
        }
        orb.dispose();
      }
      checks['turn_complete'] = completed;
      failures.addAll(checks.keys.where((k) => !checks[k]!));
      int? total(String key) =>
          usage.isNotEmpty && usage.every((v) => v != null)
          ? usage.fold<int>(0, (n, v) => n + v![key]!)
          : null;
      final report = {
        'task': 'field_manual',
        'variant': _variant,
        'provider': _provider,
        'model': _model,
        'passed': failures.isEmpty,
        'failures': failures,
        ...checks,
        'source_bytes': utf8.encode(original).length,
        'tools': tools,
        'tool_calls': tools.values.fold<int>(0, (a, b) => a + b),
        'failed_tool_calls': failuresInTools,
        'rounds': usage.length,
        'usage_rounds': usage.whereType<Map>().length,
        'input_tokens': total('input'),
        'output_tokens': total('output'),
        'cached_input_tokens': total('cached'),
        'chat_ms': elapsed.elapsedMilliseconds,
      };
      debugPrint('ORB_HOLDOUT_RESULT ${jsonEncode(report)}');
      expect(failures, isEmpty);
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 9)),
  );
}
