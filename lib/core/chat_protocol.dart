import 'dart:convert';

import 'models.dart';
import 'tool_types.dart';

class ChatOptions {
  const ChatOptions({
    this.thinking = false,
    this.search = false,
    this.readLinks = true,
    this.region,
    this.language = 'zh-CN',
    this.suggestTitle = false,
    this.safetyCheck = true,
    this.tools = const [],
    this.onTool,
  });

  final bool thinking;
  final bool search;
  final bool readLinks;
  final String? region;
  final String language;
  final bool suggestTitle;
  final bool safetyCheck;
  final List<ChatTool> tools;
  final RunChatTool? onTool;
}

class ChatDelta {
  const ChatDelta({this.text = '', this.thinking = '', this.metadata});

  final String text;
  final String thinking;
  final Map<String, dynamic>? metadata;
}

typedef ChatMessage = Map<String, dynamic>;

Map<String, Object?> _block(ModelService service, Map block) {
  final type = block['type'];
  if (type == 'text' && block['text'] is String) {
    return {
      'type': service == ModelService.openAI ? 'input_text' : 'text',
      'text': block['text'],
    };
  }
  if (type == 'image_url' && block['image_url'] is Map) {
    final image = block['image_url'] as Map;
    final url = image['url'];
    if (url is! String) throw const OrbException('未能读取图片内容。');
    return switch (service) {
      ModelService.openAI => {'type': 'input_image', 'image_url': url},
      ModelService.claude => {'type': 'image', 'source': _claudeSource(url)},
      _ => {
        'type': 'image_url',
        'image_url': {'url': url},
      },
    };
  }
  if (type == 'file') {
    final file = block['file'] is Map ? block['file'] as Map : block;
    final fields = <String, Object?>{
      for (final key in ['file_id', 'file_data', 'filename'])
        if (file[key] is String) key: file[key],
    };
    if (fields['file_id'] == null && fields['file_data'] == null) {
      throw const OrbException('未能读取文件内容。');
    }
    return switch (service) {
      ModelService.openAI => {'type': 'input_file', ...fields},
      ModelService.claude => {
        'type': 'document',
        'source': fields['file_id'] != null
            ? {'type': 'file', 'file_id': fields['file_id']}
            : _claudeSource(fields['file_data'] as String, document: true),
      },
      ModelService.deepSeek => {'type': 'file', ...fields},
      ModelService.custom => {'type': 'file', 'file': fields},
    };
  }
  throw const OrbException('所选模型接口不支持这类附件。');
}

Map<String, String> _claudeSource(String url, {bool document = false}) {
  if (!document && (url.startsWith('https://') || url.startsWith('http://'))) {
    return {'type': 'url', 'url': url};
  }
  // Keep the payload encoded: validating or decoding multi-megabyte files
  // a second time would allocate another copy on the phone.
  final prefix = RegExp(r'^data:([\w.+-]+/[\w.+-]+);base64,').firstMatch(url);
  if (prefix == null || prefix.end == url.length) {
    throw const OrbException('附件缺少有效的数据或格式。');
  }
  final mime = prefix.group(1)!;
  if (document && mime != 'application/pdf') {
    throw const OrbException('Claude 文档输入支持 PDF；其他文件请转为文本后发送。');
  }
  return {
    'type': 'base64',
    'media_type': mime,
    'data': url.substring(prefix.end),
  };
}

ChatMessage _message(ModelService service, ChatMessage message) {
  final role = message['role'];
  final content = message['content'];
  return {
    'role': role,
    'content': content is List
        ? [
            for (final b in content)
              if (b is Map) _block(service, b),
          ]
        : content,
    if (service == ModelService.deepSeek && role == 'assistant')
      for (final key in [
        'server_tool_calls',
        'reasoning_content',
        'annotations',
      ])
        if (message[key] != null) key: message[key],
  };
}

String _reminder(String region, String language) {
  final now = DateTime.now();
  final locale = language.toLowerCase().replaceAll('_', '-');
  final name = switch (locale) {
    'zh-hk' || 'zh-hant-hk' || '中文香港' => '中文香港',
    'zh-tw' || 'zh-hant' || 'zh-hant-tw' || '中文繁體' => '中文繁體',
    'english' => 'English',
    _ when locale == 'en' || locale.startsWith('en-') => 'English',
    _ => '中文',
  };
  final days = name == 'English'
      ? const [
          'Monday',
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
          'Sunday',
        ]
      : const ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  final date = now.toIso8601String().substring(0, 10);
  return '$date,${days[now.weekday - 1]},$region,App,$name';
}

Map<String, Object?> buildWireRequest(
  ModelConfig config,
  List<ChatMessage> history,
  ChatOptions options,
) {
  final service = config.service;
  final messages = [for (final m in history) _message(service, m)];
  final base = <String, Object?>{'model': config.model.trim(), 'stream': true};
  final functions = <Map<String, dynamic>>[];
  for (final tool in options.tools) {
    final definition = {'name': tool.name, 'description': tool.description};
    functions.add(switch (service) {
      ModelService.claude => {...definition, 'input_schema': tool.parameters},
      ModelService.openAI => {
        'type': 'function',
        ...definition,
        'parameters': tool.parameters,
        'strict': false,
      },
      _ => {
        'type': 'function',
        'function': {...definition, 'parameters': tool.parameters},
      },
    });
  }
  if (functions.isNotEmpty) base['tools'] = functions;
  switch (service) {
    case ModelService.claude:
      final system = messages
          .where((m) => m['role'] == 'system')
          .map((m) => m['content'])
          .whereType<String>()
          .join('\n\n');
      return {
        ...base,
        'messages': messages.where((m) => m['role'] != 'system').toList(),
        if (system.isNotEmpty) 'system': system,
        'max_tokens': 4096,
      };
    case ModelService.openAI:
      return {
        ...base,
        'input': messages,
        'store': false,
        if (functions.isNotEmpty) 'include': ['reasoning.encrypted_content'],
      };
    case ModelService.custom:
      return {...base, 'messages': messages};
    case ModelService.deepSeek:
      if (!config.supportsDeepSeekTools) {
        if (options.search) {
          throw const OrbException('联网搜索需要选择 deepseek-flash 模型。');
        }
        if (messages.any(
          (m) =>
              m['content'] is List &&
              (m['content'] as List).any(
                (b) => b is Map && b['type'] != 'text',
              ),
        )) {
          throw const OrbException('DeepSeek 图片和文件输入需要选择 deepseek-flash 模型。');
        }
        return {
          ...base,
          'messages': messages,
          'thinking': {'type': options.thinking ? 'enabled' : 'disabled'},
        };
      }
      final region = options.region?.trim();
      if (messages.isNotEmpty && messages.last['role'] == 'user') {
        messages.insert(messages.length - 1, {
          'role': 'latest_reminder',
          'content': _reminder(region ?? '', options.language),
        });
      }
      return {
        ...base,
        'messages': messages,
        'thinking': {'type': options.thinking ? 'enabled' : 'disabled'},
        if (options.search || options.readLinks)
          'tools': [
            ...functions,
            if (options.search) {'type': 'deepseek_web_search'},
            if (options.readLinks) {'type': 'deepseek_read_url'},
          ],
        if (options.suggestTitle) 'title': {'enabled': true},
        if (options.safetyCheck) 'safety_check': {'level': 'high'},
      };
  }
}

const _lengthLimit = '本次回答达到模型长度上限，可以继续提问。';
const _streamError = '模型服务返回了异常回复，请重试。';
const _refusal = '模型未能完成这次请求，请调整提问后重试。';

/// One instance per stream. DeepSeek sends citations and signed tool results
/// at the end; a later turn needs the original structures, not just the URLs.
class ChatEventReader {
  ChatEventReader(this.service);
  final ModelService service;
  bool finished = false;
  String? error;
  String? _title;
  final _native = <String, dynamic>{};
  final _citations = <String, Map<String, String>>{};
  final _reasoning = StringBuffer();

  void _cite(dynamic raw) {
    if (raw is! Map) return;
    final data = raw['url_citation'] ?? raw;
    if (data is! Map || data['url'] is! String) return;
    final url = data['url'] as String;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        !{'https', 'http'}.contains(uri.scheme)) {
      return;
    }
    _citations[url] = {
      'title': data['title'] is String ? data['title'] as String : url,
      'url': url,
    };
  }

  Map<String, dynamic>? get metadata {
    if (_title == null && _native.isEmpty && _citations.isEmpty) return null;
    return {
      if (_title != null) 'title': _title,
      if (_native.isNotEmpty) 'native': Map.of(_native),
      if (_citations.isNotEmpty) 'citations': _citations.values.toList(),
    };
  }

  ChatDelta? read(Map chunk) {
    if (chunk['error'] != null || chunk['type'] == 'error') {
      throw const OrbException(_streamError);
    }
    switch (service) {
      case ModelService.openAI:
        switch (chunk['type']) {
          case 'response.output_text.delta':
          case 'response.refusal.delta':
            return ChatDelta(text: chunk['delta'] as String? ?? '');
          case 'response.output_text.annotation.added':
            _cite(chunk['annotation']);
          case 'response.completed':
            finished = true;
          case 'response.incomplete':
            final response = chunk['response'];
            final details = response is Map
                ? response['incomplete_details']
                : null;
            throw OrbException(
              details is Map && details['reason'] == 'max_output_tokens'
                  ? _lengthLimit
                  : _refusal,
            );
          case 'response.failed':
            throw const OrbException(_streamError);
        }
        return null;
      case ModelService.claude:
        final delta = chunk['delta'];
        switch (chunk['type']) {
          case 'message_stop':
            finished = true;
          case 'content_block_delta':
            if (delta is Map && delta['type'] == 'text_delta') {
              return ChatDelta(text: delta['text'] as String? ?? '');
            }
            if (delta is Map && delta['type'] == 'thinking_delta') {
              return ChatDelta(thinking: delta['thinking'] as String? ?? '');
            }
            if (delta is Map && delta['type'] == 'citations_delta') {
              _cite(delta['citation']);
            }
          case 'message_delta':
            if (delta is Map &&
                {
                  'max_tokens',
                  'model_context_window_exceeded',
                }.contains(delta['stop_reason'])) {
              throw const OrbException(_lengthLimit);
            }
        }
        return null;
      case ModelService.deepSeek:
      case ModelService.custom:
        final choices = chunk['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) {
          return null;
        }
        final choice = choices.first as Map;
        final delta = choice['delta'];
        final reason = choice['finish_reason'];
        final text = delta is Map ? delta['content'] : null;
        String thinking = '';
        if (service == ModelService.deepSeek && delta is Map) {
          // The final reasoning field belongs only to the last tool step.
          // Earlier steps are supplied separately by the server in server_tool_calls.
          if (choice['server_tool_event'] case {
            'type': 'step_reasoning_done',
          }) {
            _reasoning.clear();
          }
          if (delta['reasoning_content'] case final String piece) {
            _reasoning.write(piece);
            thinking = piece;
          }
          if (delta['title'] case final String title) {
            if (title.trim().isNotEmpty) _title = title.trim();
          }
          for (final key in ['annotations', 'server_tool_calls']) {
            if (delta[key] is List) _native[key] = delta[key];
          }
          if (delta['annotations'] case final List refs) {
            for (final ref in refs) {
              _cite(ref);
            }
          }
          if (reason != null && _reasoning.isNotEmpty) {
            _native['reasoning_content'] = _reasoning.toString();
          }
        }
        if (reason is String && reason.isNotEmpty) {
          finished = true;
          if (reason == 'length') error = _lengthLimit;
          if (reason == 'content_filter') error = _refusal;
        }
        return ChatDelta(text: text is String ? text : '', thinking: thinking);
    }
  }
}

typedef PendingToolCall = ({String id, String name, String arguments});
typedef ChatToolReply = ({String id, String output, bool failed});

/// Collects one assistant turn in the provider's own format. Keeping reasoning
/// blocks and signatures intact lets the next request continue statelessly.
class ToolExchange {
  ToolExchange(this.service);

  final ModelService service;
  final _items = <int, Map<String, dynamic>>{};
  final _arguments = <int, StringBuffer>{};
  final _text = StringBuffer();
  String? _stopReason;

  void observe(Map chunk) {
    switch (service) {
      case ModelService.deepSeek:
      case ModelService.custom:
        final choices = chunk['choices'];
        if (choices is! List || choices.isEmpty) return;
        final choice = choices.first as Map;
        _stopReason = choice['finish_reason'] as String? ?? _stopReason;
        final delta = choice['delta'];
        if (delta is! Map) return;
        if (delta['content'] case final String text) _text.write(text);
        final fragments = delta['tool_calls'];
        if (fragments is! List) return;
        for (final fragment in fragments.whereType<Map>()) {
          final index = fragment['index'] as int? ?? 0;
          final item = _items.putIfAbsent(index, () => {});
          if (fragment['id'] case final String id) item['id'] = id;
          if (fragment['function'] case final Map function) {
            if (function['name'] case final String name) {
              item['name'] = (item['name'] as String? ?? '') + name;
            }
            if (function['arguments'] case final String part) {
              (_arguments[index] ??= StringBuffer()).write(part);
            }
          }
        }
      case ModelService.openAI:
        final index = chunk['output_index'] as int? ?? 0;
        switch (chunk['type']) {
          case 'response.output_item.added':
          case 'response.output_item.done':
            if (chunk['item'] case final Map item) {
              _items[index] = Map<String, dynamic>.from(item);
            }
          case 'response.function_call_arguments.delta':
            (_arguments[index] ??= StringBuffer()).write(
              chunk['delta'] as String,
            );
          case 'response.function_call_arguments.done':
            _arguments[index] = StringBuffer(chunk['arguments'] as String);
          case 'response.completed':
            _stopReason = 'completed';
            final response = chunk['response'];
            if (response is Map && response['output'] is List) {
              final output = response['output'] as List;
              for (var i = 0; i < output.length; i++) {
                _items[i] = Map<String, dynamic>.from(output[i] as Map);
              }
            }
        }
      case ModelService.claude:
        final index = chunk['index'] as int? ?? 0;
        switch (chunk['type']) {
          case 'content_block_start':
            _items[index] = Map<String, dynamic>.from(
              chunk['content_block'] as Map,
            );
          case 'content_block_delta':
            final item = _items[index];
            final delta = chunk['delta'];
            if (item == null || delta is! Map) return;
            switch (delta['type']) {
              case 'input_json_delta':
                (_arguments[index] ??= StringBuffer()).write(
                  delta['partial_json'] as String,
                );
              case 'text_delta':
              case 'thinking_delta':
              case 'signature_delta':
                final field = (delta['type'] as String).split('_').first;
                item[field] =
                    (item[field] as String? ?? '') + (delta[field] as String);
              case 'citations_delta':
                (item['citations'] ??= <dynamic>[]).add(delta['citation']);
            }
          case 'message_delta':
            if (chunk['delta'] case {'stop_reason': final String reason}) {
              _stopReason = reason;
            }
        }
    }
  }

  Iterable<MapEntry<int, Map<String, dynamic>>> get _orderedItems {
    final keys = _items.keys.toList()..sort();
    return keys.map((i) => MapEntry(i, _items[i]!));
  }

  List<PendingToolCall> completedCalls() {
    final calls = <PendingToolCall>[];
    final ids = <String>{};
    for (final entry in _orderedItems) {
      final item = entry.value;
      final isResponses = service == ModelService.openAI;
      if (isResponses && item['type'] != 'function_call') continue;
      if (service == ModelService.claude && item['type'] != 'tool_use') {
        continue;
      }
      final expected = switch (service) {
        ModelService.openAI => 'completed',
        ModelService.claude => 'tool_use',
        _ => 'tool_calls',
      };
      if (_stopReason != expected) throw const OrbException('工具请求未完整结束，请重试。');
      final id = item[isResponses ? 'call_id' : 'id'];
      final name = item['name'];
      if (id is! String ||
          id.isEmpty ||
          !ids.add(id) ||
          name is! String ||
          name.isEmpty) {
        throw const OrbException('服务返回的工具调用缺少有效的名称或编号。');
      }
      final String arguments;
      if (isResponses &&
          item['arguments'] is String &&
          (item['arguments'] as String).isNotEmpty) {
        arguments = item['arguments'] as String;
      } else if (_arguments.containsKey(entry.key)) {
        arguments = _arguments[entry.key].toString();
      } else {
        arguments = jsonEncode(item['input'] ?? {});
      }
      calls.add((id: id, name: name, arguments: arguments));
    }
    if (calls.isEmpty &&
        (_stopReason == 'tool_calls' || _stopReason == 'tool_use')) {
      throw const OrbException('服务没有返回完整的工具调用。');
    }
    return calls;
  }

  void appendResults(
    Map<String, Object?> body,
    List<PendingToolCall> calls,
    List<ChatToolReply> replies,
    Map<String, dynamic>? native,
  ) {
    switch (service) {
      case ModelService.openAI:
        final items = [for (final e in _orderedItems) e.value];
        for (final item in items.where((e) => e['type'] == 'function_call')) {
          item['arguments'] = calls
              .firstWhere((c) => c.id == item['call_id'])
              .arguments;
        }
        (body['input'] as List<ChatMessage>).addAll([
          ...items,
          for (final r in replies)
            {
              'type': 'function_call_output',
              'call_id': r.id,
              'output': r.output,
            },
        ]);
      case ModelService.claude:
        final blocks = [for (final e in _orderedItems) e.value];
        for (final item in blocks.where((e) => e['type'] == 'tool_use')) {
          final args = calls.firstWhere((c) => c.id == item['id']).arguments;
          // Claude requires an object even if a non-conforming tool call was rejected.
          try {
            final value = jsonDecode(args);
            item['input'] = value is Map ? value : {};
          } on FormatException {
            item['input'] = {};
          }
        }
        (body['messages'] as List<ChatMessage>).addAll([
          {'role': 'assistant', 'content': blocks},
          {
            'role': 'user',
            'content': [
              for (final r in replies)
                {
                  'type': 'tool_result',
                  'tool_use_id': r.id,
                  'content': r.output,
                  if (r.failed) 'is_error': true,
                },
            ],
          },
        ]);
      case ModelService.custom:
      case ModelService.deepSeek:
        (body['messages'] as List<ChatMessage>).add({
          'role': 'assistant',
          'content': _text.toString(),
          ...?native,
          'tool_calls': [
            for (final c in calls)
              {
                'id': c.id,
                'type': 'function',
                'function': {'name': c.name, 'arguments': c.arguments},
              },
          ],
        });
        (body['messages'] as List<ChatMessage>).addAll([
          for (final r in replies)
            {'role': 'tool', 'tool_call_id': r.id, 'content': r.output},
        ]);
    }
  }
}
