import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'chat_protocol.dart';
import 'models.dart';
import 'token_usage.dart';
import 'tool_types.dart';

export 'tool_types.dart';

export 'chat_protocol.dart' show ChatDelta, ChatMessage, ChatOptions;

abstract interface class ChatProvider {
  Stream<String> reply(ModelConfig config, List<Map<String, String>> messages);
  void stop();
}

abstract interface class RichChatProvider implements ChatProvider {
  Stream<ChatDelta> replyRich(
    ModelConfig config,
    List<ChatMessage> messages,
    ChatOptions options,
  );
}

/// An SSE JSON document may span multiple data fields. The blank line ends
/// the event; comments and named event headers do not carry model text.
Stream<String> _eventData(Stream<String> lines) async* {
  final data = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield data.join('\n');
        data.clear();
      }
    } else if (line.startsWith('data:')) {
      data.add(line.substring(5).trimLeft());
    }
  }
  if (data.isNotEmpty) yield data.join('\n');
}

class StreamingChatProvider implements RichChatProvider {
  StreamingChatProvider({
    this.usagePurpose,
    this.recordUsage = UsageLog.record,
  });
  final Future<void> Function(ModelConfig, String, Map<String, int>?)
  recordUsage;
  final String? usagePurpose;
  HttpClient? _client;

  @override
  void stop() {
    final client = _client;
    _client = null;
    client?.close(force: true);
  }

  @override
  Stream<String> reply(
    ModelConfig config,
    List<Map<String, String>> messages,
  ) => replyRich(
    config,
    messages,
    const ChatOptions(readLinks: false),
  ).where((delta) => delta.text.isNotEmpty).map((delta) => delta.text);

  @override
  Stream<ChatDelta> replyRich(
    ModelConfig config,
    List<ChatMessage> messages,
    ChatOptions options,
  ) async* {
    final validation = config.validationError;
    if (validation != null) throw OrbException(validation);
    final body = buildWireRequest(config, messages, options);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    final allowed = {for (final tool in options.tools) tool.name};
    final completed = <String, (PendingToolCall, ChatToolReply)>{};
    var executed = 0;
    var workspaceOnly = true;
    final totals = <String, int>{};
    var allUsageKnown = true;
    final citations = <String, dynamic>{};
    String? title;
    Future<HttpClientResponse> post(Map<String, Object?> payload) async {
      final request = await client.postUrl(config.endpoint);
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (config.service == ModelService.claude) {
        request.headers.set('anthropic-version', '2023-06-01');
        request.headers.set('x-api-key', config.apiKey.trim());
      } else if (config.apiKey.trim().isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${config.apiKey.trim()}',
        );
      }
      request.add(utf8.encode(jsonEncode(payload)));
      return request.close().timeout(const Duration(seconds: 90));
    }

    var includeUsage =
        usagePurpose != null && config.service == ModelService.custom;
    var toolsUnavailable = false;
    Future<HttpClientResponse> openRound(int round) async {
      // A rejected compatibility flag has not executed an inference or a local
      // action. Each flag can be removed at most once for this user turn.
      while (true) {
        final response = await post({
          ...body,
          if (includeUsage) 'stream_options': {'include_usage': true},
        });
        if (config.service != ModelService.custom ||
            (response.statusCode != 400 && response.statusCode != 422)) {
          return response;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final part in response.timeout(
          const Duration(seconds: 15),
        )) {
          if (bytes.length + part.length > 32768) break;
          bytes.add(part);
        }
        final reason = utf8
            .decode(bytes.takeBytes(), allowMalformed: true)
            .toLowerCase();
        if (includeUsage &&
            (reason.contains('stream_options') ||
                reason.contains('include_usage'))) {
          includeUsage = false;
          continue;
        }
        if (round == 0 &&
            !toolsUnavailable &&
            allowed.isNotEmpty &&
            RegExp(r'\btools?\b|function calling').hasMatch(reason) &&
            RegExp(
              r'not support|unsupported|unknown (field|parameter)|unrecognized|not allowed|cannot use tools',
            ).hasMatch(reason)) {
          body.remove('tools');
          (body['messages'] as List<ChatMessage>).insert(0, {
            'role': 'system',
            'content': '本轮服务不支持本地工具。需要实际执行的操作请说明无法执行，不要声称已完成。',
          });
          toolsUnavailable = true;
          continue;
        }
        return response;
      }
    }

    try {
      for (var round = 0; ; round++) {
        if (!identical(_client, client)) return;
        final counter = TokenCounter();
        final events = ChatEventReader(config.service);
        final exchange = ToolExchange(config.service);
        var accepted = false, finished = false, received = false;
        try {
          final response = await openRound(round);
          if (response.statusCode != 200) {
            throw OrbException(switch (response.statusCode) {
              401 || 403 => '服务拒绝了请求，请检查 API Key 和模型权限。',
              402 => '模型账户余额不足。',
              404 => '接口或模型不存在，请检查连接设置。',
              429 => '模型服务繁忙或已达额度，请稍后重试。',
              >= 500 => '模型服务暂时不可用，请稍后重试。',
              final code => '模型请求失败（HTTP $code）。',
            });
          }

          accepted = true;
          final lines = response
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 90));
          await for (final data in _eventData(lines)) {
            if (data.trim().isEmpty) continue;
            if (data.trim() == '[DONE]' &&
                (config.service == ModelService.deepSeek ||
                    config.service == ModelService.custom)) {
              events.finished = true;
              break;
            }
            final chunk = jsonDecode(data);
            if (chunk is! Map) {
              throw const FormatException('Expected an SSE object');
            }
            counter.observe(config.service, chunk);
            if (allowed.isNotEmpty && !toolsUnavailable) {
              exchange.observe(chunk);
            }
            if (config.service == ModelService.openAI &&
                const {
                  'response.incomplete',
                  'response.failed',
                }.contains(chunk['type'])) {
              finished = true;
            }
            if (config.service == ModelService.claude &&
                chunk['type'] == 'message_delta' &&
                chunk['delta'] is Map &&
                chunk['delta']['stop_reason'] != null) {
              finished = true;
            }
            final delta = events.read(chunk);
            if (events.finished) finished = true;
            if (delta != null &&
                (delta.text.isNotEmpty || delta.thinking.isNotEmpty)) {
              if (delta.text.isNotEmpty) received = true;
              yield delta;
            }
            if (events.error case final error?) throw OrbException(error);
            if (events.finished &&
                (config.service == ModelService.openAI ||
                    config.service == ModelService.claude ||
                    counter.value != null)) {
              break;
            }
          }
          if (!events.finished) throw const OrbException('连接已中断，可以重试。');
          finished = true;
        } finally {
          if (accepted && usagePurpose != null) {
            try {
              await recordUsage(
                config,
                usagePurpose!,
                finished ? counter.value : null,
              );
            } on Exception {
              // Usage history is independent of chat delivery.
            }
          }
        }
        if (!identical(_client, client)) return;
        if (counter.value case final values?) {
          for (final field in values.entries) {
            totals[field.key] = (totals[field.key] ?? 0) + field.value;
          }
        } else {
          allUsageKnown = false;
        }
        final metadata = events.metadata;
        if (metadata?['title'] case final String value) title = value;
        if (metadata?['citations'] case final List refs) {
          for (final ref in refs.whereType<Map>()) {
            if (ref['url'] case final String url) citations[url] = ref;
          }
        }
        final calls = exchange.completedCalls();
        if (calls.isEmpty) {
          if (!received) throw const OrbException('模型没有返回文字，请重试。');
          final result = {
            ...?metadata,
            'title': ?title,
            if (citations.isNotEmpty) 'citations': citations.values.toList(),
            if (allUsageKnown) 'usage': totals,
            if (toolsUnavailable) 'toolsUnavailable': true,
          };
          if (result.isNotEmpty) yield ChatDelta(metadata: result);
          return;
        }
        if (options.onTool == null || options.tools.isEmpty) {
          throw const OrbException('当前对话没有启用本地工具。');
        }
        workspaceOnly = workspaceOnly && calls.every(
          (call) => allowed.contains(call.name) && call.name.startsWith('workspace_'),
        );
        // Reading, editing and verifying a file often need separate model turns.
        // Keep the existing action budget for these, and the shorter turn limit
        // for tasks that use a scheduler, MCP server or another tool.
        if ((!workspaceOnly && round >= 6) || executed + calls.length > 16) {
          throw const OrbException('已达到本轮工具调用上限，已执行的操作仍然有效。');
        }
        final replies = <ChatToolReply>[];
        for (final call in calls) {
          if (!identical(_client, client)) return;
          final cached = completed[call.id];
          if (cached != null && cached.$1 != call) {
            throw const OrbException('服务重复使用了同一工具调用编号。');
          }
          final reply =
              cached?.$2 ?? await _runTool(call, allowed, options.onTool!);
          completed[call.id] = (call, reply);
          replies.add(reply);
        }
        executed += calls.length;
        exchange.appendResults(
          body,
          calls,
          replies,
          metadata?['native'] as Map<String, dynamic>?,
        );
      }
    } on TimeoutException {
      throw const OrbException('模型响应超时，请检查连接后重试。');
    } on IOException {
      throw const OrbException('无法连接模型服务，请检查网络和接口地址。');
    } on FormatException {
      throw const OrbException('服务未返回兼容的对话数据，请检查接口地址。');
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  Future<ChatToolReply> _runTool(
    PendingToolCall raw,
    Set<String> allowed,
    RunChatTool handler,
  ) async {
    ChatToolReply failure(String reason) =>
        (id: raw.id, output: jsonEncode({'error': reason}), failed: true);
    if (!allowed.contains(raw.name)) return failure('该工具未启用。');
    try {
      final arguments = jsonDecode(raw.arguments);
      if (arguments is! Map<String, dynamic>) {
        return failure('工具参数必须是 JSON 对象。');
      }
      final value = await handler(
        ChatToolCall(id: raw.id, name: raw.name, arguments: arguments),
      );
      return (id: raw.id, output: jsonEncode(value), failed: false);
    } on FormatException {
      return failure('工具参数格式不正确。');
    } on OrbException catch (e) {
      return failure(e.message);
    }
  }
}
