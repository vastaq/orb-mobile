import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/chat_provider.dart';
import 'package:orb_mobile/core/memory_harness.dart';
import 'package:orb_mobile/core/models.dart';

class _Provider implements ChatProvider {
  _Provider(this.result);
  final Stream<String> Function() result;
  List<Map<String, String>>? request;
  @override
  Stream<String> reply(ModelConfig config, List<Map<String, String>> messages) {
    request = messages;
    return result();
  }

  @override
  void stop() {}
}

const config = ModelConfig(apiKey: 'fixture');
const candidates = [OrbMemory('7', '我家养的猫叫小青。'), OrbMemory('9', '我的运动是游泳。')];

void main() {
  test('natural preference in a question is eligible; temporary greetings, quoted examples, and credentials do not reach planner', () async {
    const statement = '我偏爱浅色衣服，你觉得哪个好？';
    final provider = _Provider(
      () => Stream.value(
        jsonEncode({
          'ops': [
            {'kind': 'add', 'text': '我偏爱浅色衣服', 'evidence': '我偏爱浅色衣服'},
          ],
        }),
      ),
    );
    var count = 0;
    final h = MemoryHarness(
      createProvider: () {
        count++;
        return provider;
      },
    );
    for (final sample in [
      '你好！',
      '月亮是什么颜色？',
      '朋友说：“我养了猫。”',
      '我的密码是 brown-orb',
      '假设我一直喜欢吃辣。',
    ]) {
      expect(await h.plan(config, sample, []), isEmpty);
    }
    expect(count, 0);
    final result = await h.plan(config, statement, []);
    expect(result.single.kind, MemoryChangeKind.add);
    expect(result.single.text, '我偏爱浅色衣服');
    expect(count, 1);
  });

  test(
    'an invented place name never replaces verbatim user evidence',
    () async {
      const evidence = '我周末习惯去北岸蓝桥书屋看书';
      final provider = _Provider(
        () => Stream.value(
          jsonEncode({
            'ops': [
              {'kind': 'add', 'text': '习惯周末去北岸蓝梭书屋看书。', 'evidence': evidence},
            ],
          }),
        ),
      );
      final result = await MemoryHarness(createProvider: () => provider)
          .plan(config, '$evidence。', []);
      expect(result.single.text, evidence);
    },
  );

  test('updates an eligible existing ID; rejects hidden IDs, duplicate targets and false evidence', () async {
    const evidence = '我家养的猫改叫蓝豆了';
    final ops = [
      {'kind': 'update', 'id': '7', 'text': '我家养的猫叫蓝豆。', 'evidence': evidence},
      {'kind': 'update', 'id': '9', 'text': '改去爬山。', 'evidence': evidence},
      {'kind': 'add', 'text': '我家在泉州。', 'evidence': '我家在泉州'},
    ];
    final provider = _Provider(() => Stream.value(jsonEncode({'ops': ops})));
    final h = MemoryHarness(createProvider: () => provider);
    final changes = await h.plan(config, evidence, candidates);
    expect(changes.single.id, '7');
    expect(changes.single.kind, MemoryChangeKind.update);
    final packet = jsonDecode(provider.request!.last['content']!) as Map;
    expect((packet['candidates'] as List).map((c) => c['id']), ['7']);
  });

  test(
    'forget requires an explicit instruction in the user evidence',
    () async {
      for (final (input, expected) in [
        ('你知道我为什么会忘记我家养的猫叫什么吗？', false),
        ('请把我家养的猫的名字删掉。', true),
      ]) {
        final provider = _Provider(
          () => Stream.value(
            jsonEncode({
              'ops': [
                {'kind': 'forget', 'id': '7', 'evidence': input},
              ],
            }),
          ),
        );
        final changes = await MemoryHarness(createProvider: () => provider)
            .plan(config, input, candidates);
        expect(changes.isNotEmpty, expected);
        if (expected) expect(changes.single.kind, MemoryChangeKind.forget);
      }
    },
  );

  test(
    'malformed/over-budget output and requests not to save fail closed',
    () async {
      const input = '我的笔名是未央，不过不要记这件事。';
      final op = {'kind': 'add', 'text': '我笔名未央。', 'evidence': '我的笔名是未央'};
      for (final text in [
        'not json',
        jsonEncode({'ops': List.filled(4, op)}),
        jsonEncode({
          'ops': [op],
        }),
      ]) {
        final provider = _Provider(() => Stream.value(text));
        expect(
          await MemoryHarness(createProvider: () => provider)
              .plan(config, input, []),
          isEmpty,
        );
      }
    },
  );

  test(
    'cancellation rejects late output without impacting the next plan',
    () async {
      final chunks = StreamController<String>();
      final provider = _Provider(() => chunks.stream);
      final h = MemoryHarness(createProvider: () => provider);
      final pending = h.plan(config, '我一直喝无糖咖啡。', []);
      h.cancel();
      expect(await pending, isEmpty);
      chunks.add('{"ops":[]}');
      await chunks.close();
      h.dispose();
      expect(await h.plan(config, '我喜欢跑步。', []), isEmpty);
    },
  );
}
