import 'dart:convert';

import 'models.dart' show OrbAttachment, OrbMemory, OrbMessage;
import 'orb_store.dart' show OrbStore;

class PromptTemplate {
  const PromptTemplate({
    required this.id,
    required this.name,
    required this.text,
  });
  final String id, name, text;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'text': text};
  factory PromptTemplate.fromJson(Map data) => PromptTemplate(
    id: data['id'] is String ? data['id'] : '',
    name: _field(data['name'], 60),
    text: _field(data['text'], 4000),
  );
}

String _field(Object? value, int max) =>
    value is String ? String.fromCharCodes(value.trim().runes.take(max)) : '';

class PromptSettings {
  const PromptSettings({
    this.displayName = 'Orb',
    this.instructions = '',
    this.templates = const [],
  });
  final String displayName, instructions;
  final List<PromptTemplate> templates;
  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'instructions': instructions,
    'templates': templates.map((t) => t.toJson()).toList(),
  };
  factory PromptSettings.fromJson(Map data) {
    final name = _field(data['displayName'], 24);
    final raw = data['templates'];
    final ids = <String>{};
    return PromptSettings(
      displayName: name.isEmpty ? 'Orb' : name,
      instructions: _field(data['instructions'], 4000),
      templates: [
        if (raw is List)
          for (final t in raw.whereType<Map>().map(PromptTemplate.fromJson))
            if (t.id.isNotEmpty &&
                t.name.isNotEmpty &&
                t.text.isNotEmpty &&
                ids.add(t.id))
              t,
      ],
    );
  }
}

const _promptPreference = 'prompt_settings_v1';
Future<PromptSettings> loadPromptSettings(OrbStore store) async {
  final value = await store.preference(_promptPreference);
  if (value == null || value.isEmpty) return const PromptSettings();
  try {
    final data = jsonDecode(value);
    if (data is Map) return PromptSettings.fromJson(data);
  } on FormatException {
    // Other local chat settings remain available if a legacy import is malformed.
  }
  return const PromptSettings();
}

Future<void> persistPromptSettings(OrbStore store, PromptSettings settings) =>
    store.setPreference(_promptPreference, jsonEncode(settings.toJson()));

class ContextSnapshot {
  const ContextSnapshot({
    required this.keptTurns,
    required this.compressedTurns,
    required this.memoryIds,
    required this.totalMemories,
    required this.summary,
    required this.truncatedFields,
  });
  final int keptTurns, compressedTurns, totalMemories, truncatedFields;
  final List<String> memoryIds;
  final String summary;
  Map<String, dynamic> toJson() => {
    'keptTurns': keptTurns,
    'compressedTurns': compressedTurns,
    'memoryIds': memoryIds,
    'totalMemories': totalMemories,
    'summary': summary,
    'truncatedFields': truncatedFields,
  };
}

typedef _Turn = ({OrbMessage user, OrbMessage answer});

String _prefix(String value, int limit) {
  if (value.length <= limit) return value;
  var end = limit;
  if (end > 0 &&
      value.codeUnitAt(end - 1) >= 0xd800 &&
      value.codeUnitAt(end - 1) <= 0xdbff) {
    end--;
  }
  return value.substring(0, end);
}

String _excerpt(String value, int limit) {
  if (value.length <= limit) return value;
  return '${_prefix(value, limit - 1)}…';
}

String _clip(String text, int limit) {
  if (text.length <= limit) return text;
  // Keep both ends so that a closing question or a document's conclusion survives.
  const marker = '\n[…中段已压缩…]\n';
  if (limit <= marker.length + 3) return _prefix(text, limit);
  final tail = (limit - marker.length) ~/ 3;
  var start = text.length - tail;
  if (text.codeUnitAt(start) >= 0xdc00 && text.codeUnitAt(start) <= 0xdfff) {
    start++;
  }
  return '${_prefix(text, limit - marker.length - tail)}$marker${text.substring(start)}';
}

Set<String> _terms(String text) {
  final terms = <String>{};
  for (final match in RegExp(
    r'[a-z0-9]+|[\u3400-\u9fff]+',
  ).allMatches(text.toLowerCase())) {
    final word = match[0]!;
    if (word.codeUnitAt(0) < 128 || word.length == 1) {
      terms.add(word);
    } else {
      for (var i = 1; i < word.length; i++) {
        terms.add(word.substring(i - 1, i + 1));
      }
    }
  }
  return terms..removeAll(const {
    '我的',
    '一个',
    '可以',
    '什么',
    '请问',
    '这个',
    '怎么',
    'the',
    'a',
    'my',
    'is',
    'of',
    'to',
    'can',
    'you',
    'i',
  });
}

int _attachmentCost(OrbAttachment a) =>
    a.extractedText?.length ?? (a.fileId != null ? 64 : 3200);

class ContextPlan {
  const ContextPlan(
    this.system,
    this.messages,
    this.currentText,
    this.fileLimits,
    this.snapshot,
  );
  final String system, currentText;
  final List<OrbMessage> messages;
  final Map<OrbAttachment, int> fileLimits;
  final ContextSnapshot snapshot;
  String fileText(OrbAttachment a) => fileLimits.containsKey(a)
      ? _clip(a.extractedText!, fileLimits[a]!)
      : a.extractedText!;
}

/// Select the original turns once, before rendering text or native attachments.
/// Budgets count UTF-16 units, not provider-dependent tokenizer tokens.
ContextPlan planContext(
  List<OrbMessage> history,
  List<OrbMemory> memories,
  OrbMessage current, {
  PromptSettings prompts = const PromptSettings(),
}) {
  final currentText = _clip(current.text, 24000);
  final textFiles = current.attachments
      .where((a) => a.extractedText != null)
      .toList();
  final fileLimits = <OrbAttachment, int>{};
  // Reserve a share for each current document, redistributing space from short files.
  var remaining = 24000;
  textFiles.sort(
    (a, b) => a.extractedText!.length.compareTo(b.extractedText!.length),
  );
  for (var i = 0; i < textFiles.length; i++) {
    final f = textFiles[i];
    final limit = remaining ~/ (textFiles.length - i);
    final n = f.extractedText!.length.clamp(0, limit);
    if (n < f.extractedText!.length) fileLimits[f] = n;
    remaining -= n;
  }
  final inheritsTopic = RegExp(
    r'^(?:继续|接着|再来|展开|说下去|continue|go on|tell me more)',
    caseSensitive: false,
  ).hasMatch(currentText.trim());
  final recentTopic = inheritsTopic
      ? history.reversed.where((m) => m.role == 'user').firstOrNull?.text ?? ''
      : '';
  final terms = _terms(
    '${_prefix(currentText, 2000)} ${_prefix(recentTopic, 300)} ${current.attachments.map((a) => a.name).join(' ')}',
  );
  int score(String text) => _terms(text).where(terms.contains).length;
  final ranked = [
    for (final (index, memory) in memories.indexed)
      (memory: memory, score: score(memory.text), index: index),
  ];
  ranked.sort(
    (a, b) => a.score == b.score
        ? a.index.compareTo(b.index)
        : b.score.compareTo(a.score),
  );
  // Identity and response style are meaningful across topics. A direct memory
  // question can use a small fallback when phrasing has no lexical overlap.
  final global = RegExp(
    r'昵称|叫我|称呼我|我(?:的名字是|叫)[^，。！？ ]|(?:回答|回复)(?:要|请|尽量|用|简短|简洁)|(?:请|希望|喜欢)用[^。？]{1,14}(?:回答|回复)|my name is|call me|(?:respond|reply) (?:in|with|briefly)',
    caseSensitive: false,
  );
  final askingRecall = RegExp(
    r'记得|记住了什么|关于我|我.{0,22}(?:什么|哪[里个种家些]|谁|几点)|what.{0,25}(?:my|i usually)|remember',
    caseSensitive: false,
  ).hasMatch(currentText);
  final hasMatch = ranked.any((h) => h.score > 0);
  var fallback = 0;
  final notes = <OrbMemory>[];
  var noteLength = 0;
  for (final hit in ranked) {
    if (notes.length >= 12) break;
    if (hit.score == 0 && !global.hasMatch(hit.memory.text)) {
      if (hasMatch || !askingRecall || fallback >= 3) continue;
      fallback++;
    }

    if (hit.memory.text.trim().isEmpty ||
        noteLength + hit.memory.text.length > 3000) {
      continue;
    }
    notes.add(hit.memory);
    noteLength += hit.memory.text.length;
  }

  final turns = <_Turn>[];
  for (var i = 1; i < history.length; i++) {
    final user = history[i - 1], answer = history[i];
    if (user.role == 'user' &&
        answer.role == 'assistant' &&
        answer.text.isNotEmpty) {
      turns.add((user: user, answer: answer));
      i++;
    }
  }
  final selected = <_Turn>[];
  var budget =
      (32000 -
              currentText.length -
              (24000 - remaining) -
              current.attachments
                  .where((a) => a.extractedText == null)
                  .fold(0, (sum, a) => sum + _attachmentCost(a)) -
              prompts.instructions.length -
              noteLength)
          .clamp(0, 24000);
  for (final turn in turns.reversed) {
    final cost =
        turn.user.text.length +
        turn.answer.text.length +
        turn.user.attachments.fold(0, (sum, a) => sum + _attachmentCost(a));
    if (selected.length == 12 || cost > budget) break;
    selected.add(turn);
    budget -= cost;
  }
  final omitted = turns.length - selected.length;
  String line(OrbMessage m) {
    final text = _excerpt(m.text, 140).replaceAll(RegExp(r'\s+'), ' ');
    final files = m.attachments.isEmpty
        ? ''
        : ' [${_excerpt(m.attachments.map((a) => a.name).join('、'), 64)}]';
    return '$text$files';
  }

  final extracts =
      [
        for (var i = 0; i < omitted; i++)
          (
            index: i,
            score: score(
              '${_prefix(turns[i].user.text, 300)} ${_prefix(turns[i].answer.text, 300)}',
            ),
          ),
      ]..sort(
        (a, b) => a.score == b.score
            ? b.index.compareTo(a.index)
            : b.score.compareTo(a.score),
      );
  final summarized = extracts.take(4).map((h) => h.index).toList()..sort();
  final summary = [
    if (omitted > 0) '较早的 $omitted 轮对话已压缩，以下为原文节选。',
    for (final i in summarized)
      '第 ${i + 1} 轮 · 用户「${line(turns[i].user)}」 / 助手「${line(turns[i].answer)}」',
  ].join('\n');
  final system = [
    if (prompts.displayName != 'Orb') '用户为你设置的名字是${prompts.displayName}。',
    if (prompts.instructions.trim().isNotEmpty)
      '用户的个人指令：\n${prompts.instructions.trim()}',
    if (notes.isNotEmpty) '用户保存在本机的记忆：\n${notes.map((m) => m.text).join('\n')}',
    if (summary.isNotEmpty) summary,
  ].join('\n\n');
  return ContextPlan(
    system,
    [
      for (final t in selected.reversed) ...[t.user, t.answer],
      current,
    ],
    currentText,
    fileLimits,
    ContextSnapshot(
      keptTurns: selected.length,
      compressedTurns: omitted,
      memoryIds: [for (final m in notes) m.id],
      totalMemories: memories.length,
      summary: summary,
      truncatedFields:
          fileLimits.length + (current.text == currentText ? 0 : 1),
    ),
  );
}

List<Map<String, String>> buildContext(
  List<OrbMessage> history,
  List<OrbMemory> memories,
  String question, {
  PromptSettings prompts = const PromptSettings(),
  void Function(ContextSnapshot)? onSnapshot,
}) {
  final current = OrbMessage('user', question);
  final plan = planContext(history, memories, current, prompts: prompts);
  onSnapshot?.call(plan.snapshot);
  return [
    if (plan.system.isNotEmpty) {'role': 'system', 'content': plan.system},
    for (final message in plan.messages)
      {
        'role': message.role,
        'content': identical(message, current)
            ? plan.currentText
            : message.text,
      },
  ];
}
