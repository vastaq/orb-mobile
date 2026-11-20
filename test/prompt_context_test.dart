import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/models.dart';
import 'package:orb_mobile/core/turn_context.dart';
import 'package:orb_mobile/core/orb_store.dart';

class _Preferences extends Fake implements OrbStore {
  final values = <String, String>{};
  @override
  Future<String?> preference(String name) async => values[name];
  @override
  Future<void> setPreference(String name, String value) async {
    values[name] = value;
  }
}

void main() {
  test('a drink question does not inject an unrelated song into the reply', () {
    const notes = [
      OrbMemory('song', '我给正在写的曲子定名叫《晚风来信》。'),
      OrbMemory('drink', '我每天早上都喝无糖咖啡。'),
      OrbMemory('name', '我的昵称是小青。'),
    ];
    final ctx = buildContext([], notes, '我每天早上习惯喝什么？');
    expect(ctx.first['content'], contains('无糖咖啡'));
    expect(ctx.first['content'], contains('小青'));
    expect(ctx.first['content'], isNot(contains('晚风来信')));
    expect(
      buildContext([], notes.take(1).toList(), '我每天早上都喝无糖咖啡。'),
      hasLength(1),
    );
  });
  test(
    'persist personal settings; unselected template stays out of requests',
    () async {
      final store = _Preferences();
      expect((await loadPromptSettings(store)).displayName, 'Orb');
      const config = PromptSettings(
        displayName: '星子',
        instructions: '先说结论。',
        templates: [PromptTemplate(id: 't', name: '周报', text: '整理本周进展。')],
      );
      await persistPromptSettings(store, config);
      final saved = await loadPromptSettings(store);
      expect(saved.toJson(), config.toJson());
      final system = buildContext(
        [],
        [],
        '你好',
        prompts: saved,
      ).first['content']!;
      expect(system, contains('星子'));
      expect(system, contains('先说结论'));
      expect(system, isNot(contains('整理本周')));
    },
  );
  test(
    'history selects original repeated user messages including matching files',
    () async {
      const old = OrbAttachment(
        name: 'old',
        mime: 'text/plain',
        extractedText: 'old content',
      );
      const newer = OrbAttachment(
        name: 'recent',
        mime: 'text/plain',
        extractedText: 'recent content',
      );
      final history = [
        const OrbMessage('user', '相同', attachments: [old]),
        const OrbMessage('assistant', '相同答复'),
        const OrbMessage('user', '相同', attachments: [newer]),
        const OrbMessage('assistant', '相同答复'),
        const OrbMessage('user', '对话中断'),
        const OrbMessage('assistant', '', status: 'partial'),
      ];
      final context = await richContext(
        ModelConfig.deepSeek,
        history,
        [],
        const OrbMessage('user', '相同'),
      );
      expect(context[0]['content'][1]['text'], contains('old content'));
      expect(context[2]['content'][1]['text'], contains('recent content'));
      expect(context.last['content'], '相同');
    },
  );
  test('extracts earlier relevant turns, ranks memories and fairly clips current documents', () async {
    final history = [
      for (var n = 0; n < 17; n++) ...[
        OrbMessage('user', n == 0 ? '月桂桥的旧地址' : '普通问题 $n'),
        OrbMessage('assistant', '回复 $n'),
      ],
    ];
    final notes = [
      for (var i = 0; i < 18; i++) OrbMemory('$i', '杂事 $i'),
      const OrbMemory('bridge', '月桂桥在河上'),
    ];
    final long = '第一页${'文' * 32000}结尾';
    final current = OrbMessage(
      'user',
      '月桂桥',
      attachments: [
        OrbAttachment(name: '长.txt', mime: 'text/plain', extractedText: long),
        const OrbAttachment(
          name: '短.txt',
          mime: 'text/plain',
          extractedText: '全文',
        ),
      ],
    );
    late ContextSnapshot snapshot;
    final context = await richContext(
      ModelConfig.deepSeek,
      history,
      notes,
      current,
      onSnapshot: (s) => snapshot = s,
    );
    expect(snapshot.memoryIds.first, 'bridge');
    expect(snapshot.compressedTurns, 5);
    expect(snapshot.summary, contains('月桂桥的旧地址'));
    expect(snapshot.truncatedFields, 1);
    expect(context[1]['content'], '普通问题 5');
    final parts = context.last['content'];
    expect(
      parts[1]['text'],
      allOf(contains('第一页'), contains('已压缩'), contains('结尾')),
    );
    expect(parts[2]['text'], contains('全文'));
    expect(current.attachments.first.extractedText, long);
  });
}
